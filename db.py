from supabase import create_client, Client

SUPABASE_URL = "https://aaouobfmwvykhwzsdwop.supabase.co"

SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFhb3VvYmZtd3Z5a2h3enNkd29wIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTM5Njk5NCwiZXhwIjoyMDk2OTcyOTk0fQ.ZhQYSQW_jvypRC1mZjFo-R2tJDihxcdjpA9fwlpbOEs"

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)


