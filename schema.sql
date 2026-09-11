-- ============================================================
-- KOTCO（INPASS）Supabase スキーマ
-- ------------------------------------------------------------
-- Supabaseダッシュボード → SQL Editor に、このファイルの内容を
-- そのまま貼り付けて実行してください（上から順に一括実行でOK）。
-- ============================================================

-- ---------- 拡張機能 ----------
create extension if not exists "pgcrypto";

-- ============================================================
-- 1. テーブル定義
-- ============================================================

-- ユーザーのプロフィール（auth.users と1対1）
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text,
  email text,
  role text not null default 'user' check (role in ('user','organizer','staff','admin')),
  notification_enabled boolean not null default true,
  avatar_url text,
  created_at timestamptz not null default now()
);

-- イベント
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text default '',
  tagline text default '',
  category text default 'その他',
  prefecture text default '',
  city text default '',
  venue text default '',
  lat double precision,
  lng double precision,
  start_date date not null,
  end_date date not null,
  start_time time default '09:00',
  end_time time default '18:00',
  organizer_id uuid references public.profiles(id),
  organizer_name text default '',
  status text not null default 'draft' check (status in ('draft','published')),
  days jsonb default '[]',
  schedule jsonb default '{}',          -- { "8/8(土)": [ {t,title,sub}, ... ] } 簡易化のため内包
  map_pins jsonb default '[]',
  congestion_spots jsonb default '[]',
  heat jsonb default '{}',
  ticket_types jsonb default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- お知らせ
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  title text not null,
  body text not null,
  priority text not null default 'normal' check (priority in ('normal','high')),
  created_at timestamptz not null default now()
);

-- チケット（同一イベントに同一ユーザーが複数取得できないよう unique 制約）
create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  ticket_code text not null unique,           -- 表示・QR用の人間が読めるコード（INP-2026-XXXXXXXX）
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  ticket_type text,
  ticket_type_name text,
  status text not null default 'valid' check (status in ('valid','used')),
  issued_at timestamptz not null default now(),
  checked_in_at timestamptz,
  unique (event_id, user_id)
);

-- チェックイン履歴
create table if not exists public.checkins (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid,
  staff_id uuid,
  checked_in_at timestamptz not null default now()
);

-- お気に入り
create table if not exists public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

-- 混雑情報
create table if not exists public.crowd_status (
  event_id uuid not null references public.events(id) on delete cascade,
  location_id text not null,
  status int not null default 0,        -- 0=空いています 1=やや混雑 2=混雑
  updated_at timestamptz not null default now(),
  primary key (event_id, location_id)
);

-- 写真
create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  image_url text not null,
  caption text default '',
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- スタッフの担当イベント（主催者が割り当てる）
create table if not exists public.staff_assignments (
  event_id uuid not null references public.events(id) on delete cascade,
  staff_id uuid not null references public.profiles(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  primary key (event_id, staff_id)
);

-- ============================================================
-- 2. Row Level Security（RLS）を有効化
-- ============================================================
alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.announcements enable row level security;
alter table public.tickets enable row level security;
alter table public.checkins enable row level security;
alter table public.favorites enable row level security;
alter table public.crowd_status enable row level security;
alter table public.photos enable row level security;
alter table public.staff_assignments enable row level security;

-- ---------- ヘルパー関数 ----------
create or replace function public.is_admin()
returns boolean language sql stable as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.is_organizer_of(p_event_id uuid)
returns boolean language sql stable as $$
  select exists(select 1 from public.events where id = p_event_id and organizer_id = auth.uid());
$$;

create or replace function public.is_staff_of(p_event_id uuid)
returns boolean language sql stable as $$
  select exists(select 1 from public.staff_assignments where event_id = p_event_id and staff_id = auth.uid());
$$;

-- ---------- profiles ----------
create policy "profiles_select_own_or_admin" on public.profiles
  for select using (id = auth.uid() or public.is_admin());
create policy "profiles_insert_own" on public.profiles
  for insert with check (id = auth.uid() and role = 'user');
create policy "profiles_update_own" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());
-- role列の自己変更防止は下記トリガーで別途ブロックする

-- ---------- events ----------
create policy "events_select_published_or_own" on public.events
  for select using (status = 'published' or organizer_id = auth.uid() or public.is_admin());
create policy "events_insert_organizer" on public.events
  for insert with check (
    organizer_id = auth.uid()
    and exists(select 1 from public.profiles where id = auth.uid() and role in ('organizer','admin'))
  );
create policy "events_update_own" on public.events
  for update using (organizer_id = auth.uid() or public.is_admin());
create policy "events_delete_own" on public.events
  for delete using (organizer_id = auth.uid() or public.is_admin());

-- ---------- announcements ----------
create policy "announcements_select_all" on public.announcements for select using (true);
create policy "announcements_write_organizer" on public.announcements
  for all using (public.is_organizer_of(event_id) or public.is_admin())
  with check (public.is_organizer_of(event_id) or public.is_admin());

-- ---------- tickets ----------
create policy "tickets_select_own_or_staff" on public.tickets
  for select using (
    user_id = auth.uid()
    or public.is_organizer_of(event_id)
    or public.is_staff_of(event_id)
    or public.is_admin()
  );
create policy "tickets_insert_own" on public.tickets
  for insert with check (user_id = auth.uid() and status = 'valid');
-- update/delete は許可しない（チェックインは check_in_ticket() 関数経由のみ）

-- ---------- checkins ----------
create policy "checkins_select_staff_or_organizer" on public.checkins
  for select using (public.is_organizer_of(event_id) or public.is_staff_of(event_id) or public.is_admin());
-- insertは許可しない（check_in_ticket() が security definer で内部的に書き込む）

-- ---------- favorites ----------
create policy "favorites_all_own" on public.favorites
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- crowd_status ----------
create policy "crowd_select_all" on public.crowd_status for select using (true);
create policy "crowd_write_organizer" on public.crowd_status
  for all using (public.is_organizer_of(event_id) or public.is_admin())
  with check (public.is_organizer_of(event_id) or public.is_admin());

-- ---------- photos ----------
create policy "photos_select_all" on public.photos for select using (true);
create policy "photos_insert_authenticated" on public.photos
  for insert with check (auth.uid() is not null);
create policy "photos_delete_own_or_organizer" on public.photos
  for delete using (uploaded_by = auth.uid() or public.is_organizer_of(event_id) or public.is_admin());

-- ---------- staff_assignments ----------
create policy "staff_select_related" on public.staff_assignments
  for select using (staff_id = auth.uid() or public.is_organizer_of(event_id) or public.is_admin());
-- insert/deleteはRPC（assign_staff/remove_staff）経由のみ（下記）

-- ============================================================
-- 3. トリガー
-- ============================================================

-- 新規サインアップ時に profiles 行を自動作成
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email, role)
  values (new.id, new.raw_user_meta_data->>'name', new.email, 'user')
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- role列の自己変更を防止（admin_set_role() 経由、またはSQL Editor直接編集のみ許可）
create or replace function public.prevent_role_self_change()
returns trigger language plpgsql as $$
begin
  if NEW.role is distinct from OLD.role then
    if auth.uid() is not null and coalesce(current_setting('app.bypass_role_check', true), 'false') <> 'true' then
      raise exception 'ロールの変更はできません（管理者のみ変更可能です）';
    end if;
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_prevent_role_change on public.profiles;
create trigger trg_prevent_role_change
  before update on public.profiles
  for each row execute procedure public.prevent_role_self_change();

-- ============================================================
-- 4. RPC関数（SECURITY DEFINERでサーバー側の権限チェックを行う）
-- ============================================================

-- 安全なQRチェックイン：有効性・重複・担当権限をサーバー側で検証してから更新
create or replace function public.check_in_ticket(p_ticket_code text, p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_caller uuid := auth.uid();
  v_role text;
  v_is_organizer boolean;
  v_is_staff boolean;
  v_ticket record;
begin
  if v_caller is null then
    raise exception '認証が必要です';
  end if;

  select role into v_role from public.profiles where id = v_caller;
  select public.is_organizer_of(p_event_id) into v_is_organizer;
  select public.is_staff_of(p_event_id) into v_is_staff;

  if not (v_is_organizer or v_is_staff or v_role = 'admin') then
    return jsonb_build_object('status','invalid','error','このイベントのチェックイン権限がありません');
  end if;

  select * into v_ticket from public.tickets
    where ticket_code = p_ticket_code and event_id = p_event_id
    for update;

  if not found then
    return jsonb_build_object('status','invalid','ticket_code',p_ticket_code);
  end if;

  if v_ticket.status = 'used' then
    return jsonb_build_object('status','used','ticket_code',p_ticket_code,'type_name',v_ticket.ticket_type_name);
  end if;

  update public.tickets set status = 'used', checked_in_at = now() where id = v_ticket.id;
  insert into public.checkins(ticket_id, event_id, user_id, staff_id)
    values (v_ticket.id, p_event_id, v_ticket.user_id, v_caller);

  return jsonb_build_object('status','ok','ticket_code',p_ticket_code,'type_name',v_ticket.ticket_type_name);
end;
$$;
grant execute on function public.check_in_ticket(text, uuid) to authenticated;

-- 管理者専用：ユーザーのロールを変更する
create or replace function public.admin_set_role(p_target uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_caller_role text;
begin
  if p_role not in ('user','organizer','staff','admin') then
    raise exception '不正なロールです';
  end if;
  select role into v_caller_role from public.profiles where id = auth.uid();
  if v_caller_role is distinct from 'admin' then
    raise exception '管理者のみ実行できます';
  end if;
  perform set_config('app.bypass_role_check','true', true);
  update public.profiles set role = p_role where id = p_target;
end;
$$;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

-- 主催者専用：自分のイベントにスタッフを割り当てる（メールアドレス指定）
create or replace function public.assign_staff(p_event_id uuid, p_staff_email text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_staff_id uuid;
begin
  if not (public.is_organizer_of(p_event_id) or public.is_admin()) then
    raise exception 'このイベントの主催者のみスタッフを追加できます';
  end if;
  select id into v_staff_id from public.profiles where lower(email) = lower(p_staff_email);
  if v_staff_id is null then
    raise exception '指定のメールアドレスのユーザーが見つかりません（先にKOTCOへの登録が必要です）';
  end if;
  insert into public.staff_assignments(event_id, staff_id) values (p_event_id, v_staff_id)
    on conflict do nothing;
end;
$$;
grant execute on function public.assign_staff(uuid, text) to authenticated;

-- 主催者専用：自分のイベントの担当スタッフ一覧を取得（名前・メール付き）
create or replace function public.list_event_staff(p_event_id uuid)
returns table(staff_id uuid, name text, email text) language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_organizer_of(p_event_id) or public.is_admin()) then
    raise exception 'このイベントの主催者のみ閲覧できます';
  end if;
  return query
    select p.id, p.name, p.email
    from public.staff_assignments sa
    join public.profiles p on p.id = sa.staff_id
    where sa.event_id = p_event_id;
end;
$$;
grant execute on function public.list_event_staff(uuid) to authenticated;

-- 主催者専用：スタッフの担当を解除
create or replace function public.remove_staff(p_event_id uuid, p_staff_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_organizer_of(p_event_id) or public.is_admin()) then
    raise exception 'このイベントの主催者のみ実行できます';
  end if;
  delete from public.staff_assignments where event_id = p_event_id and staff_id = p_staff_id;
end;
$$;
grant execute on function public.remove_staff(uuid, uuid) to authenticated;

-- ============================================================
-- 5. Realtime を有効化（Supabaseダッシュボード「Database > Replication」
--    からでも設定できますが、SQLでも指定できます）
-- ============================================================
alter publication supabase_realtime add table public.events;
alter publication supabase_realtime add table public.announcements;
alter publication supabase_realtime add table public.crowd_status;
alter publication supabase_realtime add table public.photos;
alter publication supabase_realtime add table public.tickets;

-- ============================================================
-- 6. Storage バケット（写真アップロード用）
--    ※ バケット自体はダッシュボードの Storage 画面、または
--    以下のSQLで作成してください。
-- ============================================================
insert into storage.buckets (id, name, public)
values ('event-photos', 'event-photos', true)
on conflict (id) do nothing;

create policy "event_photos_public_read" on storage.objects
  for select using (bucket_id = 'event-photos');
create policy "event_photos_authenticated_upload" on storage.objects
  for insert with check (bucket_id = 'event-photos' and auth.uid() is not null);

-- プロフィール画像用バケット（本人のフォルダ配下にのみアップロード可）
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "avatars_public_read" on storage.objects
  for select using (bucket_id = 'avatars');
create policy "avatars_owner_upload" on storage.objects
  for insert with check (
    bucket_id = 'avatars'
    and auth.uid() is not null
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "avatars_owner_update" on storage.objects
  for update using (
    bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================
-- 7. 最初の管理者アカウントの作成方法（このSQLの実行だけでは作られません）
-- ============================================================
-- 1) アプリから通常のユーザーとして1つアカウントを新規登録する
-- 2) Supabaseダッシュボード → Table Editor → profiles テーブルを開く
-- 3) そのユーザーの role 列を 'admin' に直接書き換えて保存する
--    （Table Editorからの操作はauth.uid()を伴わないため、上記トリガーには
--    ブロックされず正常に更新できます）
-- 4) 以降は、その管理者アカウントで supabase.rpc('admin_set_role', ...) を
--    呼び出すことで、他のユーザーに organizer / staff / admin 権限を付与できます
--    （このアプリのUIには管理者向けのロール変更画面はまだ無いため、当面は
--    ブラウザの開発者ツールコンソールなどから直接呼び出してください。例：
--    await sb.rpc('admin_set_role', {p_target: '<対象のUID>', p_role: 'organizer'})）
