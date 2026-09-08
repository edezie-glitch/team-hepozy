
create table if not exists users (
  id          uuid primary key default gen_random_uuid(),
  email       text unique not null,
  username    text unique not null,
  password    text not null,
  created_at  timestamptz default now()
);

-- CONVERSATIONS
create table if not exists conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references users(id) on delete cascade,
  title       text default 'New conversation',
  created_at  timestamptz default now()
);

-- MESSAGES (every Q and A stored here)
create table if not exists messages (
  id                uuid primary key default gen_random_uuid(),
  conversation_id   uuid references conversations(id) on delete cascade,
  user_id           uuid references users(id) on delete cascade,
  role              text check (role in ('user','assistant')),
  content           text not null,
  created_at        timestamptz default now()
);

-- INDEXES for fast lookup
create index if not exists idx_messages_conv   on messages(conversation_id);
create index if not exists idx_messages_user   on messages(user_id);
create index if not exists idx_convos_user     on conversations(user_id);

-- ROW LEVEL SECURITY — users only see their own data
alter table users         enable row level security;
alter table conversations enable row level security;
alter table messages      enable row level security;

-- policies (use service role key in backend to bypass RLS)
create policy "users_own" on users
  for all using (auth.uid()::text = id::text);

create policy "convos_own" on conversations
  for all using (auth.uid()::text = user_id::text);

create policy "messages_own" on messages
  for all using (auth.uid()::text = user_id::text);