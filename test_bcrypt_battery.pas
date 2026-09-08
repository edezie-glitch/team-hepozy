program test_bcrypt_battery;
{$mode objfpc}{$H+}
uses bcryptunit, SysUtils;

var
  Failures: Integer = 0;

procedure Check(const Password, Hash: string);
begin
  if BcryptVerify(Password, Hash) then
    WriteLn('PASS: ', Copy(Password, 1, 30), '... (len=', Length(Password), ')')
  else
  begin
    WriteLn('FAIL: ', Copy(Password, 1, 30), '... (len=', Length(Password), ')');
    Inc(Failures);
  end;
end;

var
  RoundTripHash: string;
begin
  WriteLn('=== Battery: real Python bcrypt hashes, various costs/edge cases ===');
  Check('short', '$2b$04$HCeqZygRhWe0xfaZXF6AGuviGcz3oBlC9mzYUEK2a1.e4r7tiChh.');
  Check('a longer password with spaces and Numbers123', '$2b$10$b/gs4YWIOHK2HGbwU64jJukn9ZPGO.FLBGkZvnxoelGiCGUTZX2Vy');
  Check('', '$2b$04$QE2FgI8IkStyD6SLlshqQ..P6QBeKJF5tvWGwrFMBiBtMsr21ZlrO');
  Check('exactly72bytesXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX2', '$2b$06$Rp7c8ZwER/hCuciAZamsK.ozsnRQ5YWCj0LUdXCDI55lrLDNYcEhq');

  WriteLn('');
  WriteLn('=== Round-trip: Pascal-generated hash verified by Pascal ===');
  RoundTripHash := BcryptHash('roundtriptest', 4);
  WriteLn('Generated: ', RoundTripHash);
  if BcryptVerify('roundtriptest', RoundTripHash) then
    WriteLn('PASS: Pascal-generated hash self-verifies')
  else
  begin
    WriteLn('FAIL');
    Inc(Failures);
  end;

  WriteLn('');
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' FAILURE(S)');
end.
