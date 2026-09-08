unit hmacsha256unit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, sha256unit;

function HMACSHA256(const Key, Msg: string): string; // raw 32-byte binary
function HMACSHA256Hex(const Key, Msg: string): string;

implementation

const
  BLOCK_SIZE = 64;

function HMACSHA256(const Key, Msg: string): string;
var
  ActualKey: string;
  KeyPadded: array[0..BLOCK_SIZE-1] of Byte;
  IPad, OPad: array[0..BLOCK_SIZE-1] of Byte;
  I: Integer;
  InnerInput, InnerHash, OuterInput: string;
begin
  ActualKey := Key;
  if Length(ActualKey) > BLOCK_SIZE then
    ActualKey := SHA256Digest(ActualKey);

  FillChar(KeyPadded, BLOCK_SIZE, 0);
  for I := 1 to Length(ActualKey) do
    KeyPadded[I-1] := Byte(ActualKey[I]);

  for I := 0 to BLOCK_SIZE - 1 do
  begin
    IPad[I] := KeyPadded[I] xor $36;
    OPad[I] := KeyPadded[I] xor $5C;
  end;

  SetLength(InnerInput, BLOCK_SIZE);
  for I := 0 to BLOCK_SIZE - 1 do
    InnerInput[I+1] := Chr(IPad[I]);
  InnerInput := InnerInput + Msg;

  InnerHash := SHA256Digest(InnerInput);

  SetLength(OuterInput, BLOCK_SIZE);
  for I := 0 to BLOCK_SIZE - 1 do
    OuterInput[I+1] := Chr(OPad[I]);
  OuterInput := OuterInput + InnerHash;

  Result := SHA256Digest(OuterInput);
end;

function HMACSHA256Hex(const Key, Msg: string): string;
var
  Digest: string;
  I: Integer;
begin
  Digest := HMACSHA256(Key, Msg);
  Result := '';
  for I := 1 to Length(Digest) do
    Result := Result + LowerCase(IntToHex(Ord(Digest[I]), 2));
end;

end.
