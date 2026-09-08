program test_sha256;

{$mode objfpc}{$H+}

uses
  sha256unit;

var
  failures: Integer = 0;

procedure Check(const Input, Expected: string);
var
  Got: string;
begin
  Got := SHA256HexDigest(Input);
  if Got = Expected then
    WriteLn('PASS: input=', Length(Input), ' bytes -> ', Got)
  else
  begin
    WriteLn('FAIL: input=', Length(Input), ' bytes');
    WriteLn('  expected: ', Expected);
    WriteLn('  got:      ', Got);
    Inc(failures);
  end;
end;

begin
  Check('', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  Check('abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  Check('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');

  WriteLn('');
  if failures = 0 then
    WriteLn('ALL SHA-256 TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED - DO NOT USE FOR JWT SIGNING');
end.
