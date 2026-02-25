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

create table if not exists public.archived_rooms (
  id bigint generated always as identity primary key,
  room_id text not null,
  status text not null,
  archived_reason text not null default '',
  winner_side text,
  winner_seats jsonb not null default '[]'::jsonb,
  payload jsonb not null,
  created_at timestamptz,
  finished_at timestamptz,
  archived_at timestamptz not null default now()
);

create index if not exists idx_archived_rooms_archived_at
  on public.archived_rooms(archived_at desc);

create index if not exists idx_archived_rooms_room_id
  on public.archived_rooms(room_id);

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
alter table public.archived_rooms enable row level security;

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

drop policy if exists lobby_messages_delete_auth on public.lobby_messages;

-- archived_rooms：允许所有已登录用户读取；系统清理流程插入归档。
drop policy if exists archived_rooms_select_all on public.archived_rooms;
create policy archived_rooms_select_all on public.archived_rooms
for select to authenticated
using (true);

drop policy if exists archived_rooms_insert_auth on public.archived_rooms;
create policy archived_rooms_insert_auth on public.archived_rooms
for insert to authenticated
with check (true);

-- 原子回合提交：在一次事务内更新房间状态和某个玩家手牌。
-- 说明：这是“稳定性优先”的第一步，核心规则判定仍在前端，服务端先做关键身份/轮次校验。
create or replace function public.ddz_apply_room_and_hand(
  p_room_id text,
  p_expect_revision bigint,
  p_next_host_uid uuid,
  p_next_status text,
  p_next_max_members integer,
  p_next_state jsonb,
  p_actor_uid uuid default null,
  p_actor_seat integer default null,
  p_require_playing boolean default false,
  p_require_bottom_claimed boolean default false,
  p_hand_uid uuid default null,
  p_hand_cards jsonb default null
)
returns table (
  committed boolean,
  reason text,
  new_revision bigint
)
language plpgsql
security invoker
as $$
declare
  v_room public.rooms%rowtype;
  v_turn_seat integer;
  v_bottom_claimed boolean;
  v_actor_is_ai boolean;
begin
  if auth.uid() is null then
    return query select false, 'unauthenticated', null::bigint;
    return;
  end if;

  select *
    into v_room
    from public.rooms
   where room_id = p_room_id
   for update;

  if not found then
    return query select false, 'not_found', null::bigint;
    return;
  end if;

  if v_room.revision <> p_expect_revision then
    return query select false, 'conflict', v_room.revision;
    return;
  end if;

  if p_require_playing and v_room.status <> 'playing' then
    return query select false, 'status_not_playing', v_room.revision;
    return;
  end if;

  if p_require_bottom_claimed then
    begin
      v_bottom_claimed := coalesce((v_room.state->'game'->>'bottomClaimed')::boolean, false);
    exception
      when others then
        v_bottom_claimed := false;
    end;

    if not v_bottom_claimed then
      return query select false, 'bottom_unclaimed', v_room.revision;
      return;
    end if;
  end if;

  if p_actor_seat is not null then
    begin
      v_turn_seat := nullif(v_room.state->'game'->>'turnSeat', '')::integer;
    exception
      when others then
        v_turn_seat := null;
    end;

    if v_turn_seat is distinct from p_actor_seat then
      return query select false, 'turn_mismatch', v_room.revision;
      return;
    end if;

    if coalesce(v_room.state->'seats'->>(p_actor_seat::text), '') <> coalesce(p_actor_uid::text, '') then
      return query select false, 'seat_actor_mismatch', v_room.revision;
      return;
    end if;
  end if;

  if p_actor_uid is not null and p_actor_uid <> auth.uid() then
    if v_room.host_uid <> auth.uid() then
      return query select false, 'actor_forbidden', v_room.revision;
      return;
    end if;

    begin
      v_actor_is_ai := coalesce((v_room.state->'members'->(p_actor_uid::text)->>'isAi')::boolean, false);
    exception
      when others then
        v_actor_is_ai := false;
    end;

    if not v_actor_is_ai then
      return query select false, 'actor_not_ai', v_room.revision;
      return;
    end if;
  end if;

  update public.rooms
     set host_uid = p_next_host_uid,
         status = p_next_status,
         max_members = p_next_max_members,
         state = p_next_state,
         revision = v_room.revision + 1,
         updated_at = now()
   where room_id = p_room_id;

  if p_hand_uid is not null then
    insert into public.private_hands (room_id, uid, cards, updated_at)
    values (p_room_id, p_hand_uid, coalesce(p_hand_cards, '{}'::jsonb), now())
    on conflict (room_id, uid)
    do update
      set cards = excluded.cards,
          updated_at = now();
  end if;

  return query select true, 'ok', v_room.revision + 1;
end;
$$;

grant execute on function public.ddz_apply_room_and_hand(
  text, bigint, uuid, text, integer, jsonb, uuid, integer, boolean, boolean, uuid, jsonb
) to authenticated;

-- 周期清理：归档已结束房间、回收空房、清理过期留言。
create or replace function public.ddz_run_housekeeping(
  p_empty_minutes integer default 120,
  p_finished_minutes integer default 360,
  p_message_days integer default 30
)
returns table (
  archived_finished integer,
  deleted_empty integer,
  deleted_messages integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_archived integer := 0;
  v_deleted_finished integer := 0;
  v_deleted_empty integer := 0;
  v_deleted_messages integer := 0;
begin
  if auth.uid() is null then
    return query select 0, 0, 0;
    return;
  end if;

  with to_archive as (
    select r.*
    from public.rooms r
    where r.status = 'finished'
      and r.updated_at < now() - make_interval(mins => greatest(p_finished_minutes, 1))
  )
  insert into public.archived_rooms (
    room_id,
    status,
    archived_reason,
    winner_side,
    winner_seats,
    payload,
    created_at,
    finished_at
  )
  select
    t.room_id,
    t.status,
    'finished_auto',
    t.state->'game'->>'winnerSide',
    coalesce(t.state->'game'->'winnerSeats', '[]'::jsonb),
    jsonb_build_object(
      'room_id', t.room_id,
      'host_uid', t.host_uid,
      'max_members', t.max_members,
      'status', t.status,
      'state', t.state,
      'revision', t.revision,
      'created_at', t.created_at,
      'updated_at', t.updated_at
    ),
    t.created_at,
    t.updated_at
  from to_archive t;
  get diagnostics v_archived = row_count;

  delete from public.rooms r
  where r.status = 'finished'
    and r.updated_at < now() - make_interval(mins => greatest(p_finished_minutes, 1));
  get diagnostics v_deleted_finished = row_count;

  delete from public.rooms r
  where r.status = 'lobby'
    and r.updated_at < now() - make_interval(mins => greatest(p_empty_minutes, 1))
    and coalesce(jsonb_object_length(coalesce(r.state->'members', '{}'::jsonb)), 0) = 0;
  get diagnostics v_deleted_empty = row_count;

  delete from public.lobby_messages m
  where m.created_at < now() - make_interval(days => greatest(p_message_days, 1));
  get diagnostics v_deleted_messages = row_count;

  -- 返回归档数量；为避免双重统计，若删除数小于归档数，回落到删除数。
  if v_archived > v_deleted_finished then
    v_archived := v_deleted_finished;
  end if;

  return query select v_archived, v_deleted_empty, v_deleted_messages;
end;
$$;

grant execute on function public.ddz_run_housekeeping(integer, integer, integer)
to authenticated;

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
