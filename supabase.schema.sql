-- 斗地主原型（Supabase）初始化脚本
-- 在 Supabase SQL Editor 中执行

create table if not exists public.rooms (
  room_id text primary key,
  host_uid uuid not null,
  max_members integer not null default 9 check (max_members <= 9),
  status text not null default 'lobby' check (status in ('lobby', 'bidding', 'playing', 'finished')),
  state jsonb not null default '{}'::jsonb,
  revision bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.private_hands (
  room_id text not null references public.rooms(room_id) on delete cascade,
  uid uuid not null,
  cards jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (room_id, uid)
);

create table if not exists public.lobby_messages (
  id bigint generated always as identity primary key,
  uid uuid not null,
  nick text not null default '',
  message text not null,
  created_at timestamptz not null default now(),
  check (char_length(trim(message)) > 0),
  check (char_length(message) <= 200),
  check (char_length(nick) <= 24)
);

create index if not exists idx_lobby_messages_created_at
  on public.lobby_messages(created_at asc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_rooms_touch on public.rooms;
create trigger trg_rooms_touch
before update on public.rooms
for each row execute function public.touch_updated_at();

drop trigger if exists trg_hands_touch on public.private_hands;
create trigger trg_hands_touch
before update on public.private_hands
for each row execute function public.touch_updated_at();

alter table public.rooms enable row level security;
alter table public.private_hands enable row level security;
alter table public.lobby_messages enable row level security;

-- rooms：所有已登录用户可读写（原型级，便于快速联机）
drop policy if exists rooms_select_all on public.rooms;
create policy rooms_select_all on public.rooms
for select to authenticated
using (true);

drop policy if exists rooms_insert_auth on public.rooms;
create policy rooms_insert_auth on public.rooms
for insert to authenticated
with check (auth.uid() = host_uid);

drop policy if exists rooms_update_all on public.rooms;
create policy rooms_update_all on public.rooms
for update to authenticated
using (true)
with check (true);

drop policy if exists rooms_delete_all on public.rooms;
create policy rooms_delete_all on public.rooms
for delete to authenticated
using (true);

-- private_hands：默认仅本人可读写，房主可读写本房间手牌（用于发牌/底牌）
drop policy if exists hands_select_self_or_host on public.private_hands;
create policy hands_select_self_or_host on public.private_hands
for select to authenticated
using (
  uid = auth.uid()
  or exists (
    select 1 from public.rooms r
    where r.room_id = private_hands.room_id
      and r.host_uid = auth.uid()
  )
);

drop policy if exists hands_insert_self_or_host on public.private_hands;
create policy hands_insert_self_or_host on public.private_hands
for insert to authenticated
with check (
  uid = auth.uid()
  or exists (
    select 1 from public.rooms r
    where r.room_id = private_hands.room_id
      and r.host_uid = auth.uid()
  )
);

drop policy if exists hands_update_self_or_host on public.private_hands;
create policy hands_update_self_or_host on public.private_hands
for update to authenticated
using (
  uid = auth.uid()
  or exists (
    select 1 from public.rooms r
    where r.room_id = private_hands.room_id
      and r.host_uid = auth.uid()
  )
)
with check (
  uid = auth.uid()
  or exists (
    select 1 from public.rooms r
    where r.room_id = private_hands.room_id
      and r.host_uid = auth.uid()
  )
);

drop policy if exists hands_delete_self_or_host on public.private_hands;
create policy hands_delete_self_or_host on public.private_hands
for delete to authenticated
using (
  uid = auth.uid()
  or exists (
    select 1 from public.rooms r
    where r.room_id = private_hands.room_id
      and r.host_uid = auth.uid()
  )
);

-- lobby_messages：所有已登录用户可读，用户可发送自己的留言（持久化）
drop policy if exists lobby_messages_select_all on public.lobby_messages;
create policy lobby_messages_select_all on public.lobby_messages
for select to authenticated
using (true);

drop policy if exists lobby_messages_insert_self on public.lobby_messages;
create policy lobby_messages_insert_self on public.lobby_messages
for insert to authenticated
with check (
  uid = auth.uid()
  and char_length(trim(message)) > 0
  and char_length(message) <= 200
  and char_length(nick) <= 24
);

-- 实时订阅（可选，但建议打开）
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'rooms'
  ) then
    alter publication supabase_realtime add table public.rooms;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'lobby_messages'
  ) then
    alter publication supabase_realtime add table public.lobby_messages;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'private_hands'
  ) then
    alter publication supabase_realtime add table public.private_hands;
  end if;
end
$$;
