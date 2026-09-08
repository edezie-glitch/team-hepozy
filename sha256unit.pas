unit sha256unit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function SHA256Digest(const Data: string): string;      // returns raw 32-byte binary digest
function SHA256HexDigest(const Data: string): string;    // returns 64-char hex string

implementation

type
  TSHA256State = record
    H: array[0..7] of LongWord;
    Buffer: array[0..63] of Byte;
    BufferLen: Integer;
    TotalLen: QWord;
  end;

const
  K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

function RotR(X: LongWord; N: Integer): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure InitState(var State: TSHA256State);
begin
  State.H[0] := $6a09e667; State.H[1] := $bb67ae85;
  State.H[2] := $3c6ef372; State.H[3] := $a54ff53a;
  State.H[4] := $510e527f; State.H[5] := $9b05688c;
  State.H[6] := $1f83d9ab; State.H[7] := $5be0cd19;
  State.BufferLen := 0;
  State.TotalLen := 0;
end;

procedure ProcessBlock(var State: TSHA256State; const Block: array of Byte);
var
  W: array[0..63] of LongWord;
  A, B, C, D, E, F2, G, H2, T1, T2: LongWord;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (LongWord(Block[I*4]) shl 24) or (LongWord(Block[I*4+1]) shl 16) or
            (LongWord(Block[I*4+2]) shl 8) or LongWord(Block[I*4+3]);

  for I := 16 to 63 do
  begin
    W[I] := W[I-16] + (RotR(W[I-15],7) xor RotR(W[I-15],18) xor (W[I-15] shr 3))
                     + W[I-7]
                     + (RotR(W[I-2],17) xor RotR(W[I-2],19) xor (W[I-2] shr 10));
  end;

  A := State.H[0]; B := State.H[1]; C := State.H[2]; D := State.H[3];
  E := State.H[4]; F2 := State.H[5]; G := State.H[6]; H2 := State.H[7];

  for I := 0 to 63 do
  begin
    T1 := H2 + (RotR(E,6) xor RotR(E,11) xor RotR(E,25)) + ((E and F2) xor ((not E) and G)) + K[I] + W[I];
    T2 := (RotR(A,2) xor RotR(A,13) xor RotR(A,22)) + ((A and B) xor (A and C) xor (B and C));
    H2 := G; G := F2; F2 := E; E := D + T1;
    D := C; C := B; B := A; A := T1 + T2;
  end;

  State.H[0] := State.H[0] + A; State.H[1] := State.H[1] + B;
  State.H[2] := State.H[2] + C; State.H[3] := State.H[3] + D;
  State.H[4] := State.H[4] + E; State.H[5] := State.H[5] + F2;
  State.H[6] := State.H[6] + G; State.H[7] := State.H[7] + H2;
end;

function SHA256Digest(const Data: string): string;
var
  State: TSHA256State;
  Block: array[0..63] of Byte;
  I, Remaining, Offset: Integer;
  MsgLen: QWord;
  PadLen: Integer;
  FullMsg: array of Byte;
  TotalBits: QWord;
begin
  InitState(State);
  MsgLen := Length(Data);

  // pad message: 0x80, zeros, then 8-byte big-endian bit length, total multiple of 64
  PadLen := 64 - ((MsgLen + 9) mod 64);
  if PadLen = 64 then PadLen := 0;
  SetLength(FullMsg, MsgLen + 1 + PadLen + 8);

  for I := 0 to MsgLen - 1 do
    FullMsg[I] := Byte(Data[I+1]);
  FullMsg[MsgLen] := $80;
  for I := MsgLen + 1 to MsgLen + PadLen do
    FullMsg[I] := 0;

  TotalBits := MsgLen * 8;
  Offset := Length(FullMsg) - 8;
  for I := 0 to 7 do
    FullMsg[Offset + I] := Byte(TotalBits shr ((7 - I) * 8));

  I := 0;
  while I < Length(FullMsg) do
  begin
    Move(FullMsg[I], Block, 64);
    ProcessBlock(State, Block);
    Inc(I, 64);
  end;

  SetLength(Result, 32);
  for I := 0 to 7 do
  begin
    Result[I*4+1] := Chr((State.H[I] shr 24) and $FF);
    Result[I*4+2] := Chr((State.H[I] shr 16) and $FF);
    Result[I*4+3] := Chr((State.H[I] shr 8) and $FF);
    Result[I*4+4] := Chr(State.H[I] and $FF);
  end;
end;

function SHA256HexDigest(const Data: string): string;
var
  Digest: string;
  I: Integer;
begin
  Digest := SHA256Digest(Data);
  Result := '';
  for I := 1 to Length(Digest) do
    Result := Result + LowerCase(IntToHex(Ord(Digest[I]), 2));
end;

end.
