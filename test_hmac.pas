program test_hmac;

{$mode objfpc}{$H+}

uses
  hmacsha256unit;

var
  Key: string;
  I: Integer;
  Got, Expected: string;
begin
  // RFC 4231 test case 1: key = 20 bytes of 0x0b, msg = "Hi There"
  SetLength(Key, 20);
  for I := 1 to 20 do
    Key[I] := Chr($0B);

  Got := HMACSHA256Hex(Key, 'Hi There');
  Expected := 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7';
  // NOTE: RFC value is 64 hex chars; trim/compare precisely below
  Expected := Copy(Expected, 1, 64);

  WriteLn('Got:      ', Got);
  WriteLn('Expected: ', Expected);
  if Got = Expected then
    WriteLn('PASS: HMAC-SHA256 matches RFC 4231 test vector')
  else
    WriteLn('FAIL: DO NOT USE FOR JWT SIGNING');
end.
