unit jwtunit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, base64, fpjson, jsonparser, hmacsha256unit;

function Base64UrlEncode(const Data: string): string;
function Base64UrlDecode(const Data: string): string;
function JWTEncode(const PayloadJSON: TJSONObject; const Secret: string): string;
// Returns True + payload JSON if signature valid and not expired; False + reason otherwise.
function JWTDecode(const Token, Secret: string; out Payload: TJSONObject; out ErrMsg: string): Boolean;

implementation

function Base64UrlEncode(const Data: string): string;
begin
  Result := EncodeStringBase64(Data);
  Result := StringReplace(Result, '+', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  while (Length(Result) > 0) and (Result[Length(Result)] = '=') do
    Delete(Result, Length(Result), 1);
end;

function Base64UrlDecode(const Data: string): string;
var
  S: string;
  PadLen: Integer;
begin
  S := StringReplace(Data, '-', '+', [rfReplaceAll]);
  S := StringReplace(S, '_', '/', [rfReplaceAll]);
  PadLen := (4 - (Length(S) mod 4)) mod 4;
  S := S + StringOfChar('=', PadLen);
  Result := DecodeStringBase64(S);
end;

function JWTEncode(const PayloadJSON: TJSONObject; const Secret: string): string;
var
  HeaderJSON: TJSONObject;
  HeaderB64, PayloadB64, SigningInput, Signature, SigB64: string;
begin
  HeaderJSON := TJSONObject.Create;
  try
    HeaderJSON.Add('alg', 'HS256');
    HeaderJSON.Add('typ', 'JWT');
    HeaderB64  := Base64UrlEncode(HeaderJSON.AsJSON);
    PayloadB64 := Base64UrlEncode(PayloadJSON.AsJSON);
    SigningInput := HeaderB64 + '.' + PayloadB64;
    Signature := HMACSHA256(Secret, SigningInput);
    SigB64 := Base64UrlEncode(Signature);
    Result := SigningInput + '.' + SigB64;
  finally
    HeaderJSON.Free;
  end;
end;

function JWTDecode(const Token, Secret: string; out Payload: TJSONObject; out ErrMsg: string): Boolean;
var
  Parts: TStringArray;
  SigningInput, ExpectedSig, ActualSig, PayloadStr: string;
  ParsedData: TJSONData;
  ExpValue: Int64;
begin
  Result  := False;
  Payload := nil;
  ErrMsg  := '';

  Parts := Token.Split(['.']);
  if Length(Parts) <> 3 then
  begin
    ErrMsg := 'malformed token';
    Exit;
  end;

  SigningInput := Parts[0] + '.' + Parts[1];
  ExpectedSig  := HMACSHA256(Secret, SigningInput);
  ActualSig    := Base64UrlDecode(Parts[2]);

  if ExpectedSig <> ActualSig then
  begin
    ErrMsg := 'invalid signature';
    Exit;
  end;

  PayloadStr := Base64UrlDecode(Parts[1]);
  try
    ParsedData := GetJSON(PayloadStr);
  except
    ErrMsg := 'invalid payload JSON';
    Exit;
  end;

  if not (ParsedData is TJSONObject) then
  begin
    ErrMsg := 'payload is not an object';
    ParsedData.Free;
    Exit;
  end;

  Payload := TJSONObject(ParsedData);

  // expiry check — 'exp' is a Unix timestamp, per JWT spec (RFC 7519 §4.1.4)
  if Payload.Find('exp') <> nil then
  begin
    ExpValue := Payload.Get('exp', Int64(0));
    if ExpValue > 0 then
    begin
      if DateTimeToUnix(Now, False) > ExpValue then
      begin
        ErrMsg := 'token expired';
        Payload.Free;
        Payload := nil;
        Exit;
      end;
    end;
  end;

  Result := True;
end;

end.
