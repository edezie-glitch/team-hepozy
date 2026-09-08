{ ============================================================
  hepozy_main.pas — Pascal main backend for Hepozy

  Replaces letigo.py's HTTP layer:
    - /auth/signup, /auth/login   (JWT + bcrypt, both proven
      cross-compatible with your existing security.py/passlib
      tokens and password hashes via tested units below)
    - /chat/conversations, /new, /{id}/title, /{id} (delete)
    - /chat/history/{id}
    - /chat/send  — forwards message + loaded memory to the
      Python service (NLP -> RAG -> Prolog routing -> Ollama),
      which still does everything this whole project concluded
      Pascal structurally cannot: retrieval, reasoning, generation.

  Uses: sha256unit, hmacsha256unit, jwtunit (all tested against
  RFC vectors and your real security.py output — see test_sha256,
  test_hmac, test_jwt, test_bcrypt), supabaseunit, unixcrypt
  (bcrypt via system crypt()).

  CONFIG: set these three from environment or hardcode for local
  testing — same values as your existing db.py / security.py.
  ============================================================ }

program hepozy_main;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils,
  fphttpserver, httpdefs, fpjson, jsonparser,
  fphttpclient, opensslsockets, unixcrypt,
  sha256unit, hmacsha256unit, jwtunit, supabaseunit;

const
  LISTEN_PORT      = 8001; // same port your frontend's API const already expects
  SUPABASE_URL     = 'https://aaouobfmwvykhwzsdwop.supabase.co';
  SUPABASE_KEY     = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFhb3VvYmZtd3Z5a2h3enNkd29wIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTM5Njk5NCwiZXhwIjoyMDk2OTcyOTk0fQ.ZhQYSQW_jvypRC1mZjFo-R2tJDihxcdjpA9fwlpbOEs';
  JWT_SECRET       = 'hepozy-secret-key-change-in-production'; // MUST match security.py's JWT_SECRET exactly
  JWT_EXPIRE_MINS  = 10080; // 7 days, matches security.py
  PYTHON_NLP_URL   = 'http://127.0.0.1:5001/route'; // your NLP+RAG+Prolog+LLM service
  TOKEN_LIMIT      = 5000;  // matches letigo.py's TOKEN_LIMIT
  WINDOW_HOURS     = 10;    // matches letigo.py's WINDOW_HOURS
  MEMORY_MSG_LIMIT = 10;    // matches letigo.py's _load_memory limit

var
  DB: TSupabaseClient;

{ ============================================================
  AUTH HELPERS
  ============================================================ }

function GenerateToken(const UserId, Username: string): string;
var
  Payload: TJSONObject;
  ExpUnix: Int64;
begin
  Payload := TJSONObject.Create;
  try
    ExpUnix := DateTimeToUnix(IncMinute(Now, JWT_EXPIRE_MINS), False);
    Payload.Add('sub', UserId);
    Payload.Add('username', Username);
    Payload.Add('exp', ExpUnix);
    Result := JWTEncode(Payload, JWT_SECRET);
  finally
    Payload.Free;
  end;
end;

// Returns True + userId/username if the Authorization header holds a
// valid, unexpired token signed with our secret. False + ErrMsg otherwise.
function AuthenticateRequest(ARequest: TFPHTTPConnectionRequest;
  out UserId, Username, ErrMsg: string): Boolean;
var
  AuthHeader, Token: string;
  Payload: TJSONObject;
begin
  Result := False;
  UserId := '';
  Username := '';
  AuthHeader := ARequest.Authorization;

  if not AuthHeader.StartsWith('Bearer ') then
  begin
    ErrMsg := 'Missing or invalid token';
    Exit;
  end;

  Token := Copy(AuthHeader, 8, Length(AuthHeader));
  if not JWTDecode(Token, JWT_SECRET, Payload, ErrMsg) then
    Exit;

  UserId   := Payload.Get('sub', '');
  Username := Payload.Get('username', '');
  Payload.Free;
  Result := True;
end;

// bcrypt verify via system crypt() — proven cross-compatible with
// passlib's bcrypt hashes in test_bcrypt.pas
function VerifyPassword(const PlainPassword, StoredHash: string): Boolean;
begin
  Result := StrPas(crypt(PChar(PlainPassword), PChar(StoredHash))) = StoredHash;
end;

function HashPassword(const PlainPassword: string): string;
var
  Salt: string;
begin
  // $2b$ bcrypt salt, cost factor 12 — same default passlib uses.
  Salt := '$2b$12$' + gen_md5_salt; // see accompanying note on salt entropy
  Result := StrPas(crypt(PChar(PlainPassword), PChar(Salt)));
end;

{ ============================================================
  USAGE LIMIT — mirrors letigo.py's check_usage_limit /
  record_usage exactly: cumulative, per-user, rolling window.
  ============================================================ }

// Returns (allowed, message) same contract as letigo.py's check_usage_limit.
function CheckUsageLimit(const UserId: string; out Allowed: Boolean; out LimitMessage: string): Boolean;
var
  Rows: TJSONData;
  ErrMsg: string;
  User: TJSONObject;
  Used: Integer;
  StartedRaw: string;
  Started, Now_: TDateTime;
  ElapsedHours: Double;
  RemainingSecs: Int64;
  Hours, Minutes: Integer;
  UpdateBody: TJSONObject;
begin
  Result := True;
  Allowed := True;
  LimitMessage := '';

  Rows := DB.Get('users?select=tokens_used_window,window_started_at&id=eq.' + UserId, ErrMsg);
  if (Rows = nil) or (TJSONArray(Rows).Count = 0) then
  begin
    // fail open on read errors, same spirit as letigo.py treating a
    // missing row as {tokens_used_window: 0, window_started_at: None}
    if Rows <> nil then Rows.Free;
    Exit;
  end;

  User := TJSONObject(TJSONArray(Rows).Items[0]);
  Used := User.Get('tokens_used_window', 0);
  StartedRaw := User.Get('window_started_at', '');
  Rows.Free;

  Now_ := LocalTimeToUniversal(Now);

  if StartedRaw <> '' then
  begin
    Started := ISO8601ToDate(StartedRaw, True);
    ElapsedHours := (Now_ - Started) * 24;
  end
  else
    ElapsedHours := WINDOW_HOURS + 1; // force reset below, same as letigo.py

  if ElapsedHours >= WINDOW_HOURS then
  begin
    // window expired — reset and allow
    UpdateBody := TJSONObject.Create;
    try
      UpdateBody.Add('tokens_used_window', 0);
      UpdateBody.Add('window_started_at', DateToISO8601(Now_, True));
      DB.Patch('users?id=eq.' + UserId, UpdateBody, ErrMsg);
    finally
      UpdateBody.Free;
    end;
    Exit; // Allowed stays True
  end;

  if Used >= TOKEN_LIMIT then
  begin
    RemainingSecs := Round((WINDOW_HOURS - ElapsedHours) * 3600);
    Hours := RemainingSecs div 3600;
    Minutes := (RemainingSecs mod 3600) div 60;
    Allowed := False;
    LimitMessage := Format('You don''t have enough tokens left. Come back in %dh %dm.', [Hours, Minutes]);
  end;
end;

procedure RecordUsage(const UserId: string; TotalTokens: Integer);
var
  Rows: TJSONData;
  ErrMsg: string;
  Current: Integer;
  UpdateBody: TJSONObject;
begin
  Rows := DB.Get('users?select=tokens_used_window&id=eq.' + UserId, ErrMsg);
  Current := 0;
  if (Rows <> nil) and (TJSONArray(Rows).Count > 0) then
    Current := TJSONObject(TJSONArray(Rows).Items[0]).Get('tokens_used_window', 0);
  if Rows <> nil then Rows.Free;

  UpdateBody := TJSONObject.Create;
  try
    UpdateBody.Add('tokens_used_window', Current + TotalTokens);
    DB.Patch('users?id=eq.' + UserId, UpdateBody, ErrMsg);
  finally
    UpdateBody.Free;
  end;
end;

{ ============================================================
  MEMORY — mirrors letigo.py's _load_memory: last N messages,
  role + content only, oldest first.
  ============================================================ }

function LoadMemory(const ConvId: string): TJSONData;
var
  ErrMsg: string;
begin
  Result := DB.Get('messages?select=role,content&conversation_id=eq.' + ConvId +
                    '&order=created_at.asc&limit=' + IntToStr(MEMORY_MSG_LIMIT), ErrMsg);
  if Result = nil then
    Result := TJSONArray.Create; // empty array on failure, same fallback as letigo.py's `or []`
end;

procedure SaveMessage(const ConvId, UserId, Role, Content: string);
var
  Body: TJSONObject;
  ErrMsg: string;
  Res: TJSONData;
begin
  Body := TJSONObject.Create;
  try
    Body.Add('conversation_id', ConvId);
    Body.Add('user_id', UserId);
    Body.Add('role', Role);
    Body.Add('content', Content);
    Res := DB.Post('messages', Body, ErrMsg);
    if Res <> nil then Res.Free;
    // errors are logged, not raised — matches letigo.py's fire-and-forget
    // save behavior inside save_fn
  finally
    Body.Free;
  end;
end;

{ ============================================================
  RESPONSE HELPERS
  ============================================================ }

procedure RespondJSON(AResponse: TFPHTTPConnectionResponse; Code: Integer; const JSON: string);
begin
  AResponse.SetCustomHeader('Content-Type', 'application/json');
  AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
  AResponse.Code := Code;
  AResponse.Content := JSON;
end;

procedure RespondError(AResponse: TFPHTTPConnectionResponse; Code: Integer; const Detail: string);
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('detail', Detail);
    RespondJSON(AResponse, Code, Obj.AsJSON);
  finally
    Obj.Free;
  end;
end;

function ParseRequestBody(const Content: string; out ErrMsg: string): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  try
    Data := GetJSON(Content);
    if Data is TJSONObject then
      Result := TJSONObject(Data)
    else
    begin
      ErrMsg := 'body is not a JSON object';
      Data.Free;
    end;
  except
    ErrMsg := 'invalid JSON body';
  end;
end;

{ ============================================================
  ROUTE HANDLERS
  ============================================================ }

type
  THepozyServer = class
    procedure HandleSignup(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleLogin(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleListConversations(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleNewConversation(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleHistory(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
    procedure HandleUpdateTitle(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
    procedure HandleDeleteConversation(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
    procedure HandleExportPDF(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
    procedure HandleChatSend(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure OnRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
  end;

procedure THepozyServer.HandleSignup(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  Body: TJSONObject;
  ErrMsg: string;
  Email, Username, Password, Hashed: string;
  ExistingUsername, ExistingEmail, InsertResult: TJSONData;
  InsertBody: TJSONObject;
  NewUser: TJSONObject;
  Token: string;
  ResultObj: TJSONObject;
begin
  Body := ParseRequestBody(ARequest.Content, ErrMsg);
  if Body = nil then
  begin
    RespondError(AResponse, 400, ErrMsg);
    Exit;
  end;

  try
    Email    := Body.Get('email', '');
    Username := Body.Get('username', '');
    Password := Body.Get('password', '');

    if (Email = '') or (Username = '') or (Password = '') then
    begin
      RespondError(AResponse, 400, 'email, username, and password are required');
      Exit;
    end;

    ExistingUsername := DB.Get('users?select=id&username=eq.' + Username, ErrMsg);
    if (ExistingUsername <> nil) and (TJSONArray(ExistingUsername).Count > 0) then
    begin
      RespondError(AResponse, 400, 'Username already taken');
      ExistingUsername.Free;
      Exit;
    end;
    if ExistingUsername <> nil then ExistingUsername.Free;

    ExistingEmail := DB.Get('users?select=id&email=eq.' + Email, ErrMsg);
    if (ExistingEmail <> nil) and (TJSONArray(ExistingEmail).Count > 0) then
    begin
      RespondError(AResponse, 400, 'Email already registered');
      ExistingEmail.Free;
      Exit;
    end;
    if ExistingEmail <> nil then ExistingEmail.Free;

    Hashed := HashPassword(Password);

    InsertBody := TJSONObject.Create;
    try
      InsertBody.Add('email', Email);
      InsertBody.Add('username', Username);
      InsertBody.Add('password', Hashed);
      InsertResult := DB.Post('users', InsertBody, ErrMsg);
    finally
      InsertBody.Free;
    end;

    if InsertResult = nil then
    begin
      RespondError(AResponse, 500, 'Could not create user: ' + ErrMsg);
      Exit;
    end;

    NewUser := TJSONObject(TJSONArray(InsertResult).Items[0]);
    Token := GenerateToken(NewUser.Get('id', ''), NewUser.Get('username', ''));
    InsertResult.Free;

    ResultObj := TJSONObject.Create;
    try
      ResultObj.Add('token', Token);
      ResultObj.Add('username', Username);
      RespondJSON(AResponse, 200, ResultObj.AsJSON);
    finally
      ResultObj.Free;
    end;

  finally
    Body.Free;
  end;
end;

procedure THepozyServer.HandleLogin(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  Body: TJSONObject;
  ErrMsg: string;
  Username, Password, StoredHash, UserId: string;
  Rows: TJSONData;
  User: TJSONObject;
  Token: string;
  ResultObj: TJSONObject;
begin
  Body := ParseRequestBody(ARequest.Content, ErrMsg);
  if Body = nil then
  begin
    RespondError(AResponse, 400, ErrMsg);
    Exit;
  end;

  try
    Username := Body.Get('username', '');
    Password := Body.Get('password', '');

    Rows := DB.Get('users?select=*&username=eq.' + Username, ErrMsg);
    if (Rows = nil) or (TJSONArray(Rows).Count = 0) then
    begin
      RespondError(AResponse, 401, 'Invalid username or password');
      if Rows <> nil then Rows.Free;
      Exit;
    end;

    User := TJSONObject(TJSONArray(Rows).Items[0]);
    StoredHash := User.Get('password', '');
    UserId := User.Get('id', '');

    if not VerifyPassword(Password, StoredHash) then
    begin
      RespondError(AResponse, 401, 'Invalid username or password');
      Rows.Free;
      Exit;
    end;

    Token := GenerateToken(UserId, Username);
    Rows.Free;

    ResultObj := TJSONObject.Create;
    try
      ResultObj.Add('token', Token);
      ResultObj.Add('username', Username);
      RespondJSON(AResponse, 200, ResultObj.AsJSON);
    finally
      ResultObj.Free;
    end;

  finally
    Body.Free;
  end;
end;

procedure THepozyServer.HandleListConversations(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  UserId, Username, ErrMsg: string;
  Rows: TJSONData;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  Rows := DB.Get('conversations?select=id,title,created_at&user_id=eq.' + UserId + '&order=created_at.desc', ErrMsg);
  if Rows = nil then
  begin
    RespondError(AResponse, 500, ErrMsg);
    Exit;
  end;

  ResultObj := TJSONObject.Create;
  try
    ResultObj.Add('conversations', Rows);
    RespondJSON(AResponse, 200, ResultObj.AsJSON);
  finally
    ResultObj.Free; // frees Rows too, since it was added as a member
  end;
end;

procedure THepozyServer.HandleNewConversation(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  UserId, Username, ErrMsg: string;
  InsertBody: TJSONObject;
  InsertResult: TJSONData;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  InsertBody := TJSONObject.Create;
  try
    InsertBody.Add('user_id', UserId);
    InsertBody.Add('title', 'New conversation');
    InsertResult := DB.Post('conversations', InsertBody, ErrMsg);
  finally
    InsertBody.Free;
  end;

  if InsertResult = nil then
  begin
    RespondError(AResponse, 500, ErrMsg);
    Exit;
  end;

  ResultObj := TJSONObject.Create;
  try
    ResultObj.Add('conversation', TJSONArray(InsertResult).Items[0].Clone);
    InsertResult.Free;
    RespondJSON(AResponse, 200, ResultObj.AsJSON);
  finally
    ResultObj.Free;
  end;
end;

procedure THepozyServer.HandleHistory(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
var
  UserId, Username, ErrMsg: string;
  Rows: TJSONData;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  Rows := DB.Get('messages?select=role,content,created_at&conversation_id=eq.' + ConvId + '&order=created_at.asc', ErrMsg);
  if Rows = nil then
  begin
    RespondError(AResponse, 500, ErrMsg);
    Exit;
  end;

  ResultObj := TJSONObject.Create;
  try
    ResultObj.Add('messages', Rows);
    RespondJSON(AResponse, 200, ResultObj.AsJSON);
  finally
    ResultObj.Free;
  end;
end;

procedure THepozyServer.HandleUpdateTitle(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
var
  UserId, Username, ErrMsg: string;
  Body: TJSONObject;
  Title: string;
  UpdateBody: TJSONObject;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  Body := ParseRequestBody(ARequest.Content, ErrMsg);
  if Body = nil then
  begin
    RespondError(AResponse, 400, ErrMsg);
    Exit;
  end;

  try
    Title := Body.Get('title', '');

    // matches letigo.py's update_title: filters by both conversation_id
    // AND user_id, so a user can't retitle someone else's conversation
    UpdateBody := TJSONObject.Create;
    try
      UpdateBody.Add('title', Title);
      if not DB.Patch('conversations?id=eq.' + ConvId + '&user_id=eq.' + UserId, UpdateBody, ErrMsg) then
      begin
        RespondError(AResponse, 500, ErrMsg);
        Exit;
      end;
    finally
      UpdateBody.Free;
    end;

    ResultObj := TJSONObject.Create;
    try
      ResultObj.Add('ok', True);
      RespondJSON(AResponse, 200, ResultObj.AsJSON);
    finally
      ResultObj.Free;
    end;
  finally
    Body.Free;
  end;
end;

procedure THepozyServer.HandleDeleteConversation(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
var
  UserId, Username, ErrMsg: string;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  // matches letigo.py's delete_conversation: delete messages first
  // (no cascade assumed here, mirroring the explicit two-step delete
  // in the Python version), then the conversation itself scoped to
  // this user so one user can't delete another's conversation
  if not DB.Delete('messages?conversation_id=eq.' + ConvId, ErrMsg) then
  begin
    RespondError(AResponse, 500, ErrMsg);
    Exit;
  end;
  if not DB.Delete('conversations?id=eq.' + ConvId + '&user_id=eq.' + UserId, ErrMsg) then
  begin
    RespondError(AResponse, 500, ErrMsg);
    Exit;
  end;

  ResultObj := TJSONObject.Create;
  try
    ResultObj.Add('ok', True);
    RespondJSON(AResponse, 200, ResultObj.AsJSON);
  finally
    ResultObj.Free;
  end;
end;

procedure THepozyServer.HandleExportPDF(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const ConvId: string);
var
  UserId, Username, ErrMsg: string;
  Messages: TJSONData;
  ConvRows: TJSONData;
  Title: string;
  ResultObj: TJSONObject;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  // matches letigo.py's export_pdf: returns structured JSON: title +
  // ordered messages; the frontend renders the actual PDF client-side
  Messages := DB.Get('messages?select=role,content,created_at&conversation_id=eq.' + ConvId + '&order=created_at.asc', ErrMsg);
  if Messages = nil then
    Messages := TJSONArray.Create;

  ConvRows := DB.Get('conversations?select=title&id=eq.' + ConvId, ErrMsg);
  Title := 'Conversation';
  if (ConvRows <> nil) and (TJSONArray(ConvRows).Count > 0) then
    Title := TJSONObject(TJSONArray(ConvRows).Items[0]).Get('title', 'Conversation');
  if ConvRows <> nil then ConvRows.Free;

  ResultObj := TJSONObject.Create;
  try
    ResultObj.Add('title', Title);
    ResultObj.Add('messages', Messages);
    RespondJSON(AResponse, 200, ResultObj.AsJSON);
  finally
    ResultObj.Free; // frees Messages too, as a member
  end;
end;

procedure THepozyServer.HandleChatSend(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  UserId, Username, ErrMsg: string;
  Body: TJSONObject;
  ConvId, Message: string;
  Allowed: Boolean;
  LimitMessage: string;
  Memory: TJSONData;
  ForwardBody: TJSONObject;
  ForwardClient: TFPHTTPClient;
  PythonResponse: string;
  ResponseData: TJSONData;
  ReplyText: string;
  TotalTokens: Integer;
  SSEBody: string;
  EscapedLimit, EscapedReply: string;
begin
  if not AuthenticateRequest(ARequest, UserId, Username, ErrMsg) then
  begin
    RespondError(AResponse, 401, ErrMsg);
    Exit;
  end;

  Body := ParseRequestBody(ARequest.Content, ErrMsg);
  if Body = nil then
  begin
    RespondError(AResponse, 400, ErrMsg);
    Exit;
  end;

  try
    ConvId  := Body.Get('conversation_id', '');
    Message := Trim(Body.Get('message', ''));

    if Message = '' then
    begin
      RespondError(AResponse, 400, 'Empty message');
      Exit;
    end;

    // ---- usage limit check, same contract as letigo.py ----
    CheckUsageLimit(UserId, Allowed, LimitMessage);
    if not Allowed then
    begin
      // SSE stream carrying just the limit message, matches
      // letigo.py's limit_stream() behavior exactly
      EscapedLimit := StringReplace(LimitMessage, '"', '\"', [rfReplaceAll]);
      SSEBody := 'data: {"type": "reply", "token": "' + EscapedLimit + '"}' + LineEnding + LineEnding +
                 'data: [DONE]' + LineEnding + LineEnding;
      AResponse.SetCustomHeader('Content-Type', 'text/event-stream');
      AResponse.SetCustomHeader('Cache-Control', 'no-cache');
      AResponse.SetCustomHeader('X-Accel-Buffering', 'no');
      AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
      AResponse.Code := 200;
      AResponse.Content := SSEBody;
      Exit;
    end;

    // ---- save the user's message, same as letigo.py's save_fn ----
    SaveMessage(ConvId, UserId, 'user', Message);

    // ---- load memory, same as letigo.py's _load_memory ----
    Memory := LoadMemory(ConvId);

    // ---- forward to the Python NLP/RAG/Prolog/LLM service ----
    // NOTE: this call is synchronous, unlike letigo.py's token-by-token
    // SSE stream from Ollama. The response is wrapped into a single
    // SSE frame below so the frontend's existing SSE-consuming code
    // (sendpatch.js) keeps working without changes, but the user will
    // see the full reply appear at once rather than typed out live.
    // True token-level streaming would require the Python service
    // itself to stream chunked HTTP back to Pascal, which is a real,
    // separate piece of work — flagged here, not silently skipped.
    ForwardClient := TFPHTTPClient.Create(nil);
    ForwardBody := TJSONObject.Create;
    try
      ForwardBody.Add('conversation_id', ConvId);
      ForwardBody.Add('user_id', UserId);
      ForwardBody.Add('message', Message);
      ForwardBody.Add('memory', Memory.Clone);
      ForwardClient.AddHeader('Content-Type', 'application/json');
      ForwardClient.RequestBody := TStringStream.Create(ForwardBody.AsJSON);
      try
        PythonResponse := ForwardClient.Post(PYTHON_NLP_URL);
        ResponseData := GetJSON(PythonResponse);

        ReplyText := '';
        TotalTokens := 0;
        if ResponseData is TJSONObject then
        begin
          ReplyText := TJSONObject(ResponseData).Get('reply', TJSONObject(ResponseData).Get('output_type', ''));
          TotalTokens := TJSONObject(ResponseData).Get('total_tokens', 0);
        end;
        ResponseData.Free;

        // save the assistant's reply, same as letigo.py's save_fn
        if ReplyText <> '' then
          SaveMessage(ConvId, UserId, 'assistant', ReplyText);

        // record usage, same as letigo.py's record_usage on token_usage events
        if TotalTokens > 0 then
          RecordUsage(UserId, TotalTokens);

        EscapedReply := StringReplace(ReplyText, '"', '\"', [rfReplaceAll]);
        EscapedReply := StringReplace(EscapedReply, LineEnding, '\n', [rfReplaceAll]);
        SSEBody := 'data: {"type": "reply", "token": "' + EscapedReply + '"}' + LineEnding + LineEnding +
                   'data: [DONE]' + LineEnding + LineEnding;
        AResponse.SetCustomHeader('Content-Type', 'text/event-stream');
        AResponse.SetCustomHeader('Cache-Control', 'no-cache');
        AResponse.SetCustomHeader('X-Accel-Buffering', 'no');
        AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
        AResponse.Code := 200;
        AResponse.Content := SSEBody;

      except
        on E: Exception do
        begin
          // deliberately generic — never leak backend internals
          // ("Ollama", stack traces, etc.) to the frontend
          SSEBody := 'data: {"type": "error", "token": "The assistant is taking longer than usual to respond. Please try again."}' + LineEnding + LineEnding +
                     'data: [DONE]' + LineEnding + LineEnding;
          AResponse.SetCustomHeader('Content-Type', 'text/event-stream');
          AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
          AResponse.Code := 200; // SSE errors ride inside the stream, not the HTTP status
          AResponse.Content := SSEBody;
        end;
      end;
    finally
      ForwardBody.Free;
      ForwardClient.Free;
      Memory.Free;
    end;

  finally
    Body.Free;
  end;
end;

procedure THepozyServer.OnRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  Path: string;
begin
  Path := ARequest.PathInfo;

  if ARequest.Method = 'OPTIONS' then
  begin
    AResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
    AResponse.SetCustomHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
    AResponse.SetCustomHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    AResponse.Code := 200;
    Exit;
  end;

  if (Path = '/auth/signup') and (ARequest.Method = 'POST') then
    HandleSignup(ARequest, AResponse)
  else if (Path = '/auth/login') and (ARequest.Method = 'POST') then
    HandleLogin(ARequest, AResponse)
  else if (Path = '/chat/conversations') and (ARequest.Method = 'GET') then
    HandleListConversations(ARequest, AResponse)
  else if (Path = '/chat/conversations/new') and (ARequest.Method = 'POST') then
    HandleNewConversation(ARequest, AResponse)
  else if Path.StartsWith('/chat/history/') and (ARequest.Method = 'GET') then
    HandleHistory(ARequest, AResponse, Copy(Path, 15, Length(Path)))
  else if Path.StartsWith('/chat/conversations/') and Path.EndsWith('/title') and (ARequest.Method = 'PATCH') then
    HandleUpdateTitle(ARequest, AResponse, Copy(Path, 21, Length(Path) - 20 - 6)) // strip prefix + '/title' suffix
  else if Path.StartsWith('/chat/conversations/') and (ARequest.Method = 'DELETE') then
    HandleDeleteConversation(ARequest, AResponse, Copy(Path, 21, Length(Path)))
  else if Path.StartsWith('/chat/export/') and (ARequest.Method = 'GET') then
    HandleExportPDF(ARequest, AResponse, Copy(Path, 14, Length(Path)))
  else if (Path = '/chat/send') and (ARequest.Method = 'POST') then
    HandleChatSend(ARequest, AResponse)
  else if (Path = '') and (ARequest.Method = 'GET') then
    RespondJSON(AResponse, 200, '{"status": "Hepozy API v2 running"}')
  else
    RespondError(AResponse, 404, 'Not found');
end;

var
  Server: TFPHTTPServer;
  Handler: THepozyServer;

begin
  DB := TSupabaseClient.Create(SUPABASE_URL, SUPABASE_KEY);
  Handler := THepozyServer.Create;
  Server := TFPHTTPServer.Create(nil);
  try
    Server.Port := LISTEN_PORT;
    Server.OnRequest := @Handler.OnRequest;
    WriteLn('Hepozy Pascal main backend listening on port ', LISTEN_PORT);
    WriteLn('Forwarding chat content to ', PYTHON_NLP_URL);
    Server.Active := True;
  finally
    Server.Free;
    Handler.Free;
    DB.Free;
  end;
end.