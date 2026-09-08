unit supabaseunit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, fphttpclient, opensslsockets;

type
  TSupabaseClient = class
  private
    FUrl: string;
    FKey: string;
    function BuildClient: TFPHTTPClient;
  public
    constructor Create(const AUrl, AKey: string);
    // returns parsed JSON array/object response, or nil + sets ErrMsg on failure
    function Get(const Path: string; out ErrMsg: string): TJSONData;
    function Post(const Path: string; const Body: TJSONObject; out ErrMsg: string): TJSONData;
    function Patch(const Path: string; const Body: TJSONObject; out ErrMsg: string): Boolean;
    function Delete(const Path: string; out ErrMsg: string): Boolean;
  end;

implementation

constructor TSupabaseClient.Create(const AUrl, AKey: string);
begin
  FUrl := AUrl;
  FKey := AKey;
end;

function TSupabaseClient.BuildClient: TFPHTTPClient;
begin
  Result := TFPHTTPClient.Create(nil);
  Result.AddHeader('apikey', FKey);
  Result.AddHeader('Authorization', 'Bearer ' + FKey);
  Result.AddHeader('Content-Type', 'application/json');
end;

function TSupabaseClient.Get(const Path: string; out ErrMsg: string): TJSONData;
var
  Client: TFPHTTPClient;
  ResponseStream: TStringStream;
  ResponseBody: string;
begin
  Result := nil;
  ErrMsg := '';
  Client := BuildClient;
  ResponseStream := TStringStream.Create('');
  try
    try
      // pass an empty allowed-codes array so HTTPMethod does NOT raise on
      // non-2xx — we want the actual body Supabase sent back, always
      Client.AllowRedirect := True;
      Client.HTTPMethod('GET', FUrl + '/rest/v1/' + Path, ResponseStream, []);
      ResponseBody := ResponseStream.DataString;
      if Client.ResponseStatusCode >= 200 then
        if Client.ResponseStatusCode < 300 then
          Result := GetJSON(ResponseBody)
        else
          ErrMsg := 'supabase returned ' + IntToStr(Client.ResponseStatusCode) + ': ' + ResponseBody
      else
        ErrMsg := 'no response status';
    except
      on E: Exception do
        ErrMsg := 'supabase GET failed: ' + E.Message + ' | body=' + ResponseStream.DataString;
    end;
  finally
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TSupabaseClient.Post(const Path: string; const Body: TJSONObject; out ErrMsg: string): TJSONData;
var
  Client: TFPHTTPClient;
  BodyStream: TStringStream;
  ResponseStream: TMemoryStream;
  ResponseText: string;
begin
  Result := nil;
  ErrMsg := '';
  Client := BuildClient;
  Client.AddHeader('Prefer', 'return=representation');
  BodyStream := TStringStream.Create(Body.AsJSON);
  ResponseStream := TMemoryStream.Create;
  try
    try
      Client.RequestBody := BodyStream;
      Client.HTTPMethod('POST', FUrl + '/rest/v1/' + Path, ResponseStream, []);
      ResponseStream.Position := 0;
      SetLength(ResponseText, ResponseStream.Size);
      if ResponseStream.Size > 0 then
        ResponseStream.ReadBuffer(ResponseText[1], ResponseStream.Size);

      if (Client.ResponseStatusCode >= 200) and (Client.ResponseStatusCode < 300) then
        Result := GetJSON(ResponseText)
      else
        ErrMsg := 'supabase POST returned ' + IntToStr(Client.ResponseStatusCode) + ': ' + ResponseText;
    except
      on E: Exception do
        ErrMsg := 'supabase POST failed: ' + E.Message;
    end;
  finally
    BodyStream.Free;
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TSupabaseClient.Patch(const Path: string; const Body: TJSONObject; out ErrMsg: string): Boolean;
var
  Client: TFPHTTPClient;
  BodyStream: TStringStream;
  ResponseStream: TMemoryStream;
begin
  Result := False;
  ErrMsg := '';
  Client := BuildClient;
  BodyStream := TStringStream.Create(Body.AsJSON);
  ResponseStream := TMemoryStream.Create;
  try
    try
      Client.RequestBody := BodyStream;
      Client.HTTPMethod('PATCH', FUrl + '/rest/v1/' + Path, ResponseStream, []);
      if (Client.ResponseStatusCode >= 200) and (Client.ResponseStatusCode < 300) then
        Result := True
      else
      begin
        ResponseStream.Position := 0;
        SetLength(ErrMsg, ResponseStream.Size);
        if ResponseStream.Size > 0 then
          ResponseStream.ReadBuffer(ErrMsg[1], ResponseStream.Size);
        ErrMsg := 'supabase PATCH returned ' + IntToStr(Client.ResponseStatusCode) + ': ' + ErrMsg;
      end;
    except
      on E: Exception do
        ErrMsg := 'supabase PATCH failed: ' + E.Message;
    end;
  finally
    BodyStream.Free;
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TSupabaseClient.Delete(const Path: string; out ErrMsg: string): Boolean;
var
  Client: TFPHTTPClient;
  ResponseStream: TMemoryStream;
begin
  Result := False;
  ErrMsg := '';
  Client := BuildClient;
  ResponseStream := TMemoryStream.Create;
  try
    try
      Client.HTTPMethod('DELETE', FUrl + '/rest/v1/' + Path, ResponseStream, []);
      if (Client.ResponseStatusCode >= 200) and (Client.ResponseStatusCode < 300) then
        Result := True
      else
      begin
        ResponseStream.Position := 0;
        SetLength(ErrMsg, ResponseStream.Size);
        if ResponseStream.Size > 0 then
          ResponseStream.ReadBuffer(ErrMsg[1], ResponseStream.Size);
        ErrMsg := 'supabase DELETE returned ' + IntToStr(Client.ResponseStatusCode) + ': ' + ErrMsg;
      end;
    except
      on E: Exception do
        ErrMsg := 'supabase DELETE failed: ' + E.Message;
    end;
  finally
    ResponseStream.Free;
    Client.Free;
  end;
end;

end.
