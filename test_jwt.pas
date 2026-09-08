program test_jwt;

{$mode objfpc}{$H+}

uses
  fpjson, jwtunit;

const
  SECRET = 'hepozy-secret-key-change-in-production';
  PYTHON_TOKEN = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0LXVzZXItaWQiLCJ1c2VybmFtZSI6InRlc3R1c2VyIiwiZXhwIjoxNzk4NzYxNjAwfQ.1EVHxw66t3WujQzLdyp0Ey23LbHkMx-OgfU4wD9nYZY';

var
  Payload: TJSONObject;
  ErrMsg: string;
  OK: Boolean;
  NewPayload: TJSONObject;
  NewToken: string;
begin
  WriteLn('=== TEST 1: verify a token produced by Python (security.py/python-jose) ===');
  OK := JWTDecode(PYTHON_TOKEN, SECRET, Payload, ErrMsg);
  if OK then
  begin
    WriteLn('PASS: signature verified in Pascal');
    WriteLn('  sub      = ', Payload.Get('sub', ''));
    WriteLn('  username = ', Payload.Get('username', ''));
    Payload.Free;
  end
  else
    WriteLn('FAIL: ', ErrMsg);

  WriteLn('');
  WriteLn('=== TEST 2: verify signature rejection on tampered token ===');
  OK := JWTDecode(PYTHON_TOKEN + 'x', SECRET, Payload, ErrMsg);
  if not OK then
    WriteLn('PASS: tampered token correctly rejected (', ErrMsg, ')')
  else
  begin
    WriteLn('FAIL: tampered token was accepted — this is a security bug');
    Payload.Free;
  end;

  WriteLn('');
  WriteLn('=== TEST 3: verify wrong secret is rejected ===');
  OK := JWTDecode(PYTHON_TOKEN, 'wrong-secret', Payload, ErrMsg);
  if not OK then
    WriteLn('PASS: wrong secret correctly rejected (', ErrMsg, ')')
  else
  begin
    WriteLn('FAIL: wrong secret was accepted — this is a security bug');
    Payload.Free;
  end;

  WriteLn('');
  WriteLn('=== TEST 4: encode a token in Pascal, decode it back in Pascal ===');
  NewPayload := TJSONObject.Create;
  NewPayload.Add('sub', 'pascal-user-id');
  NewPayload.Add('username', 'pascaluser');
  NewPayload.Add('exp', Int64(1798761600));
  NewToken := JWTEncode(NewPayload, SECRET);
  NewPayload.Free;

  WriteLn('  generated: ', NewToken);

  OK := JWTDecode(NewToken, SECRET, Payload, ErrMsg);
  if OK then
  begin
    WriteLn('PASS: Pascal-generated token verifies correctly');
    WriteLn('  sub      = ', Payload.Get('sub', ''));
    Payload.Free;
  end
  else
    WriteLn('FAIL: ', ErrMsg);
end.
