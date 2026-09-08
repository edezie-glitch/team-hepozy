program test_bcrypt_pascal;
{$mode objfpc}{$H+}
uses bcryptunit, SysUtils;

const
  PASSWORD = 'mypassword123';
  REAL_HASH = '$2b$12$x13QD6QoJexkL.7xc890v..LowBCgZIbuo1vd7p0TuskeduaWRFQC';
  WRONG_PASSWORD = 'wrongpassword';

var
  Result1, Result2: Boolean;
begin
  WriteLn('=== TEST: verify correct password against real Python bcrypt hash ===');
  Result1 := BcryptVerify(PASSWORD, REAL_HASH);
  if Result1 then
    WriteLn('PASS: pure-Pascal bcrypt correctly verified a real Python-generated hash')
  else
    WriteLn('FAIL: pure-Pascal bcrypt did NOT reproduce the correct hash');

  WriteLn('');
  WriteLn('=== TEST: reject wrong password ===');
  Result2 := BcryptVerify(WRONG_PASSWORD, REAL_HASH);
  if not Result2 then
    WriteLn('PASS: wrong password correctly rejected')
  else
    WriteLn('FAIL: wrong password was accepted - security bug');
end.
