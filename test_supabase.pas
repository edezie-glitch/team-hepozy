program test_supabase;

{$mode objfpc}{$H+}

uses
  fpjson, supabaseunit, SysUtils;

const
  SUPABASE_URL = 'https://aaouobfmwvykhwzsdwop.supabase.co';
  SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFhb3VvYmZtd3Z5a2h3enNkd29wIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTM5Njk5NCwiZXhwIjoyMDk2OTcyOTk0fQ.ZhQYSQW_jvypRC1mZjFo-R2tJDihxcdjpA9fwlpbOEs';

var
  Client: TSupabaseClient;
  Response: TJSONData;
  ErrMsg: string;
begin
  Client := TSupabaseClient.Create(SUPABASE_URL, SUPABASE_KEY);
  try
    WriteLn('=== TEST: query users table (should return real rows or empty array) ===');
    Response := Client.Get('users?select=username&limit=3', ErrMsg);
    if Assigned(Response) then
    begin
      WriteLn('PASS: got response from Supabase');
      WriteLn(Response.AsJSON);
      Response.Free;
    end
    else
      WriteLn('FAIL: ', ErrMsg);
  finally
    Client.Free;
  end;
end.
