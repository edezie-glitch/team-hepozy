 

program hepozy host;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  fphttpserver, httpdefs, fpjson, jsonparser,
  fphttpclient;

const
  LISTEN_PORT     = 9000;
  PYTHON_SERVICE  = 'http://127.0.0.1:5001/route';
  MAX_MESSAGE_LEN = 4000; // basic sanitization bound

{ ---- basic input validation ---- }
function ValidateMessage(const Msg: string; out ErrMsg: string): Boolean;
begin
  Result := True;
  ErrMsg := '';

  if Trim(Msg) = '' then
  begin
    ErrMsg := 'message field is empty';
    Result := False;
    Exit;
  end;

  if Length(Msg) > MAX_MESSAGE_LEN then
  begin
    ErrMsg := 'message exceeds maximum length';
    Result := False;
    Exit;
  end;
end;

{ ---- forward validated question to the Python service ---- }
function ForwardToPython(const Msg: string; out ResponseBody: string): Boolean;
var
  Client: TFPHTTPClient;
  RequestJSON: TJSONObject;
  RequestStream: TStringStream;
begin
  Result := True;
  Client := TFPHTTPClient.Create(nil);
  RequestJSON := TJSONObject.Create;
  try
    RequestJSON.Add('message', Msg);
    RequestStream := TStringStream.Create(RequestJSON.AsJSON);
    try
      Client.AddHeader('Content-Type', 'application/json');
      Client.RequestBody := RequestStream;
      try
        ResponseBody := Client.Post(PYTHON_SERVICE);
      except
        on E: Exception do
        begin
          ResponseBody := '{"error": "python service unreachable: ' +
                           StringReplace(E.Message, '"', '''', [rfReplaceAll]) + '"}';
          Result := False;
        end;
      end;
    finally
      RequestStream.Free;
    end;
  finally
    RequestJSON.Free;
    Client.Free;
  end;
end;

{ ---- main HTTP request handler (must be an object method for
        TFPHTTPServer.OnRequest, not a plain procedure) ---- }
type
  THepozyHandler = class
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  end;

procedure THepozyHandler.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  ReqJSON: TJSONData;
  Msg, ErrMsg, PythonResponse: string;
  ResultOK: Boolean;
begin
  AResponse.SetCustomHeader('Content-Type', 'application/json');

  if ARequest.Method <> 'POST' then
  begin
    AResponse.Code := 405;
    AResponse.Content := '{"error": "only POST is supported"}';
    Exit;
  end;

  { ---- parse + validate input ---- }
  try
    ReqJSON := GetJSON(ARequest.Content);
  except
    AResponse.Code := 400;
    AResponse.Content := '{"error": "invalid JSON body"}';
    Exit;
  end;

  try
    if not (ReqJSON is TJSONObject) or (TJSONObject(ReqJSON).Find('message') = nil) then
    begin
      AResponse.Code := 400;
      AResponse.Content := '{"error": "missing message field"}';
      Exit;
    end;

    Msg := TJSONObject(ReqJSON).Get('message', '');

    if not ValidateMessage(Msg, ErrMsg) then
    begin
      AResponse.Code := 400;
      AResponse.Content := '{"error": "' + ErrMsg + '"}';
      Exit;
    end;

    { ---- forward to Python, get result, pass through ---- }
    ResultOK := ForwardToPython(Msg, PythonResponse);

    if ResultOK then
    begin
      AResponse.Code := 200;
      AResponse.Content := PythonResponse;
    end
    else
    begin
      AResponse.Code := 502;
      AResponse.Content := PythonResponse; { already formatted as error JSON }
    end;

  finally
    ReqJSON.Free;
  end;
end;

var
  Server: TFPHTTPServer;
  Handler: THepozyHandler;

begin
  Server := TFPHTTPServer.Create(nil);
  Handler := THepozyHandler.Create;
  try
    Server.Port := LISTEN_PORT;
    Server.OnRequest := @Handler.HandleRequest;
    WriteLn('Hepozy Pascal host listening on port ', LISTEN_PORT);
    WriteLn('Forwarding validated requests to ', PYTHON_SERVICE);
    Server.Active := True;
  finally
    Handler.Free;
    Server.Free;
  end;
end.