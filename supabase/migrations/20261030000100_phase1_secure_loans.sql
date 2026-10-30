-- Phase 1: secure loan operations.
-- Additive only: every object uses IF NOT EXISTS / OR REPLACE and nothing is dropped.
-- If the existing app keeps loans in a table with another name or other column
-- names, reconcile that before applying (see INTEGRATION.md, "Existing loans table").

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Roles: stored apart from profile fields. New accounts get no role at all.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.app_role as enum ('management', 'processor');
exception when duplicate_object then null; end $$;

create table if not exists public.user_roles (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       public.app_role not null,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

-- Named processors exist independently of logins, so spreadsheet rows can be
-- assigned (Purple -> Bobbie, etc.) before each person's account is linked.
create table if not exists public.processors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(trim(name)) between 1 and 80),
  user_id    uuid unique references auth.users(id) on delete set null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.processors (name) values ('Bobbie'), ('Adel'), ('Katie'), ('Moe')
on conflict (name) do nothing;

create or replace function public.is_management()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'management');
$$;

create or replace function public.my_processor_id()
returns uuid language sql stable security definer set search_path = public as $$
  select p.id from public.processors p
  join public.user_roles r on r.user_id = p.user_id and r.role = 'processor'
  where p.user_id = auth.uid() and p.active;
$$;

-- Bootstrap the first management account. Not executable by app users:
-- run it from the SQL editor (service role) once the management login exists.
create or replace function public.bootstrap_management(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then raise exception 'No account with email %', p_email; end if;
  insert into public.user_roles (user_id, role) values (v_user, 'management') on conflict do nothing;
end $$;
revoke all on function public.bootstrap_management(text) from public, anon, authenticated;

-- Management-only: grant or revoke a role.
create or replace function public.set_user_role(p_user uuid, p_role public.app_role, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_management() then raise exception 'Only management can change roles' using errcode = '42501'; end if;
  if p_enabled then
    insert into public.user_roles (user_id, role, granted_by) values (p_user, p_role, auth.uid()) on conflict do nothing;
  else
    if p_role = 'management' and (select count(*) from public.user_roles where role = 'management') <= 1 then
      raise exception 'Cannot remove the last management account';
    end if;
    delete from public.user_roles where user_id = p_user and role = p_role;
  end if;
end $$;

-- Management-only: link a login to a named processor (and give it the processor role).
create or replace function public.link_processor_account(p_processor uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_management() then raise exception 'Only management can link processor accounts' using errcode = '42501'; end if;
  update public.processors set user_id = p_user where id = p_processor;
  if p_user is not null then
    insert into public.user_roles (user_id, role, granted_by) values (p_user, 'processor', auth.uid()) on conflict do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Stages (mirrors src/lib/stages.ts)
-- ---------------------------------------------------------------------------
create table if not exists public.loan_stages (
  key         text primary key,
  label       text not null,
  position    int,            -- pipeline order; null for exception stages
  is_finished boolean not null
);

insert into public.loan_stages (key, label, position, is_finished) values
  ('application',        'Application',        0, false),
  ('submitted',          'Submitted',          1, false),
  ('esigned',            'E-signed',           2, false),
  ('documents_received', 'Documents received', 3, false),
  ('rate_locked',        'Rate locked',        4, false),
  ('underwriting',       'Underwriting',       5, false),
  ('approved',           'Approved',           6, false),
  ('clear_to_close',     'Clear to close',     7, false),
  ('closing',            'Closing',            8, false),
  ('funded',             'Funded',             9, true),
  ('on_hold',            'On hold',         null, false),
  ('restructured',       'Restructured',    null, false),
  ('denied',             'Denied',          null, true),
  ('cancelled',          'Cancelled',       null, true)
on conflict (key) do update set label = excluded.label, position = excluded.position, is_finished = excluded.is_finished;

create table if not exists public.milestone_types (
  key      text primary key,
  label    text not null,
  stage    text not null references public.loan_stages(key),
  position int not null
);

insert into public.milestone_types (key, label, stage, position) values
  ('submission',     'Submission',         'submitted',          1),
  ('esign',          'E-signing',          'esigned',            2),
  ('documents',      'Documents received', 'documents_received', 3),
  ('rate_lock',      'Rate lock',          'rate_locked',        4),
  ('underwriting',   'Underwriting',       'underwriting',       5),
  ('approval',       'Approval',           'approved',           6),
  ('clear_to_close', 'Clear to close',     'clear_to_close',     7),
  ('closing',        'Closing',            'closing',            8),
  ('funding',        'Funding',            'funded',             9)
on conflict (key) do update set label = excluded.label, stage = excluded.stage, position = excluded.position;

-- ---------------------------------------------------------------------------
-- Loans: existing fields preserved, new fields added.
-- ---------------------------------------------------------------------------
create table if not exists public.loans (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table public.loans
  add column if not exists borrower_name       text,
  add column if not exists co_borrower_name    text,
  add column if not exists borrower_email      text,
  add column if not exists borrower_phone      text,
  add column if not exists property_address    text,
  add column if not exists loan_number         text,
  add column if not exists lender_loan_number  text,
  add column if not exists loan_amount         numeric(14,2),
  add column if not exists loan_type           text,
  add column if not exists lender_name         text,
  add column if not exists loan_officer        text,
  add column if not exists processor_id        uuid references public.processors(id),
  add column if not exists stage               text not null default 'application' references public.loan_stages(key),
  add column if not exists stage_changed_at    timestamptz not null default now(),
  add column if not exists application_date    date,
  add column if not exists closing_date        date,
  add column if not exists funding_date        date,
  add column if not exists rate_lock_expires   date,
  add column if not exists notes               text,
  add column if not exists created_by          uuid references auth.users(id) default auth.uid(),
  add column if not exists updated_at          timestamptz not null default now();

do $$ begin
  alter table public.loans add constraint loans_amount_nonneg check (loan_amount is null or loan_amount >= 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.loans add constraint loans_borrower_len check (borrower_name is null or length(borrower_name) <= 200);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.loans add constraint loans_email_shape check (borrower_email is null or borrower_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$');
exception when duplicate_object then null; end $$;

create unique index if not exists loans_loan_number_uq on public.loans (loan_number) where loan_number is not null;
create index if not exists loans_processor_idx on public.loans (processor_id);
create index if not exists loans_stage_idx on public.loans (stage);
create index if not exists loans_closing_idx on public.loans (closing_date);
create index if not exists loans_funding_idx on public.loans (funding_date);

create table if not exists public.loan_milestones (
  loan_id      uuid not null references public.loans(id) on delete cascade,
  milestone    text not null references public.milestone_types(key),
  completed_at timestamptz,             -- null = reopened / not complete
  completed_by uuid references auth.users(id),
  primary key (loan_id, milestone)
);

-- Append-only history. Rows are written only by triggers below.
create table if not exists public.loan_events (
  id         bigint generated always as identity primary key,
  loan_id    uuid not null references public.loans(id) on delete cascade,
  event_type text not null,
  from_value text,
  to_value   text,
  detail     jsonb not null default '{}',
  actor_id   uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists loan_events_loan_idx on public.loan_events (loan_id, created_at);

create or replace function public.log_loan_event(p_loan uuid, p_type text, p_from text, p_to text, p_detail jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into public.loan_events (loan_id, event_type, from_value, to_value, detail, actor_id)
  values (p_loan, p_type, p_from, p_to, coalesce(p_detail, '{}'), auth.uid());
$$;
revoke all on function public.log_loan_event(uuid, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public.can_access_loan(p_loan uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_management()
      or exists (select 1 from public.loans l where l.id = p_loan and l.processor_id = public.my_processor_id());
$$;

-- Guard: who may assign a loan, and stamp timestamps.
create or replace function public.loans_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_management() then
    if tg_op = 'INSERT' then
      new.processor_id := coalesce(new.processor_id, public.my_processor_id());
      if new.processor_id is distinct from public.my_processor_id() then
        raise exception 'Processors can only create loans assigned to themselves' using errcode = '42501';
      end if;
    elsif new.processor_id is distinct from old.processor_id then
      raise exception 'Only management can reassign loans' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    if new.stage is distinct from old.stage then new.stage_changed_at := now(); end if;
  end if;
  return new;
end $$;

drop trigger if exists loans_before_write on public.loans;
create trigger loans_before_write before insert or update on public.loans
  for each row execute function public.loans_before_write();

-- History + stage->milestone sync, for every write path (forms, imports, SQL).
create or replace function public.loans_after_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_milestone text;
begin
  if tg_op = 'INSERT' then
    perform public.log_loan_event(new.id, 'created', null, new.stage, jsonb_build_object('processor_id', new.processor_id));
  else
    if new.stage is distinct from old.stage then
      perform public.log_loan_event(new.id, 'stage_changed', old.stage, new.stage);
    end if;
    if new.processor_id is distinct from old.processor_id then
      perform public.log_loan_event(new.id, 'reassigned', old.processor_id::text, new.processor_id::text);
    end if;
    if new.closing_date is distinct from old.closing_date then
      perform public.log_loan_event(new.id, 'closing_date_changed', old.closing_date::text, new.closing_date::text);
    end if;
    if new.funding_date is distinct from old.funding_date then
      perform public.log_loan_event(new.id, 'funding_date_changed', old.funding_date::text, new.funding_date::text);
    end if;
    if new.rate_lock_expires is distinct from old.rate_lock_expires then
      perform public.log_loan_event(new.id, 'rate_lock_changed', old.rate_lock_expires::text, new.rate_lock_expires::text);
    end if;
  end if;

  -- A stage set directly (not via the milestone button) still records its milestone date.
  if tg_op = 'INSERT' or new.stage is distinct from old.stage then
    select key into v_milestone from public.milestone_types where stage = new.stage;
    if v_milestone is not null then
      insert into public.loan_milestones (loan_id, milestone, completed_at, completed_by)
      values (new.id, v_milestone, now(), auth.uid())
      on conflict (loan_id, milestone) do update
        set completed_at = now(), completed_by = auth.uid()
        where loan_milestones.completed_at is null;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists loans_after_write on public.loans;
create trigger loans_after_write after insert or update on public.loans
  for each row execute function public.loans_after_write();

-- Milestone -> stage sync and history.
create or replace function public.loan_milestones_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and (old.completed_at is null) = (new.completed_at is null) then return new; end if;
  -- Depth > 1 means the loans trigger is recording the milestone for a stage it was just set to.
  if pg_trigger_depth() = 1 and (select s.is_finished from public.loans l join public.loan_stages s on s.key = l.stage where l.id = new.loan_id) then
    raise exception 'Loan is finished; milestones cannot change';
  end if;
  new.completed_by := case when new.completed_at is null then null else coalesce(new.completed_by, auth.uid()) end;
  return new;
end $$;

drop trigger if exists loan_milestones_guard on public.loan_milestones;
create trigger loan_milestones_guard before insert or update on public.loan_milestones
  for each row execute function public.loan_milestones_guard();

create or replace function public.loan_milestones_sync_stage()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stage   text;
  v_cur_pos int;
  v_target  text;
  v_tpos    int;
  v_was boolean := tg_op = 'UPDATE' and old.completed_at is not null;
  v_is  boolean := new.completed_at is not null;
begin
  if v_was = v_is then return null; end if;

  if v_is then
    perform public.log_loan_event(new.loan_id, 'milestone_completed', null, new.milestone,
      jsonb_build_object('completed_at', new.completed_at));
  else
    perform public.log_loan_event(new.loan_id, 'milestone_reopened', new.milestone, null,
      jsonb_build_object('was_completed_at', old.completed_at));
  end if;

  select l.stage, s.position into v_stage, v_cur_pos
    from public.loans l join public.loan_stages s on s.key = l.stage
   where l.id = new.loan_id for update of l;
  if v_cur_pos is null then return null; end if;   -- on hold / restructured keep their stage

  if v_is then
    select s.key, s.position into v_target, v_tpos
      from public.milestone_types m join public.loan_stages s on s.key = m.stage
     where m.key = new.milestone;
    if v_tpos > v_cur_pos then
      update public.loans set stage = v_target where id = new.loan_id;
    end if;
  elsif v_stage = (select stage from public.milestone_types where key = new.milestone) then
    -- Reopened the milestone that set the current stage: fall back to the highest one still complete.
    select s.key into v_target
      from public.loan_milestones lm
      join public.milestone_types m on m.key = lm.milestone
      join public.loan_stages s on s.key = m.stage
     where lm.loan_id = new.loan_id and lm.completed_at is not null
     order by s.position desc limit 1;
    update public.loans set stage = coalesce(v_target, 'application') where id = new.loan_id;
  end if;
  return null;
end $$;

drop trigger if exists loan_milestones_sync_stage on public.loan_milestones;
create trigger loan_milestones_sync_stage after insert or update on public.loan_milestones
  for each row execute function public.loan_milestones_sync_stage();

-- One-click milestone completion / reopen used by the UI.
create or replace function public.complete_milestone(p_loan uuid, p_milestone text)
returns public.loan_milestones language plpgsql security invoker set search_path = public as $$
declare r public.loan_milestones;
begin
  if not public.can_access_loan(p_loan) then raise exception 'Not permitted' using errcode = '42501'; end if;
  insert into public.loan_milestones (loan_id, milestone, completed_at, completed_by)
  values (p_loan, p_milestone, now(), auth.uid())
  on conflict (loan_id, milestone) do update set completed_at = now(), completed_by = auth.uid()
    where loan_milestones.completed_at is null
  returning * into r;
  if r is null then select * into r from public.loan_milestones where loan_id = p_loan and milestone = p_milestone; end if;
  return r;
end $$;

create or replace function public.reopen_milestone(p_loan uuid, p_milestone text)
returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.can_access_loan(p_loan) then raise exception 'Not permitted' using errcode = '42501'; end if;
  update public.loan_milestones set completed_at = null where loan_id = p_loan and milestone = p_milestone;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.user_roles      enable row level security;
alter table public.processors      enable row level security;
alter table public.loan_stages     enable row level security;
alter table public.milestone_types enable row level security;
alter table public.loans           enable row level security;
alter table public.loan_milestones enable row level security;
alter table public.loan_events     enable row level security;

drop policy if exists user_roles_read on public.user_roles;
create policy user_roles_read on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.is_management());
-- No write policies: roles change only through set_user_role / link_processor_account.

drop policy if exists processors_read on public.processors;
create policy processors_read on public.processors for select to authenticated using (true);
drop policy if exists processors_manage on public.processors;
create policy processors_manage on public.processors for all to authenticated
  using (public.is_management()) with check (public.is_management());

drop policy if exists loan_stages_read on public.loan_stages;
create policy loan_stages_read on public.loan_stages for select to authenticated using (true);
drop policy if exists milestone_types_read on public.milestone_types;
create policy milestone_types_read on public.milestone_types for select to authenticated using (true);

drop policy if exists loans_select on public.loans;
create policy loans_select on public.loans for select to authenticated
  using (public.is_management() or processor_id = public.my_processor_id());
drop policy if exists loans_insert on public.loans;
create policy loans_insert on public.loans for insert to authenticated
  with check (public.is_management() or processor_id = public.my_processor_id());
drop policy if exists loans_update on public.loans;
create policy loans_update on public.loans for update to authenticated
  using (public.is_management() or processor_id = public.my_processor_id())
  with check (public.is_management() or processor_id = public.my_processor_id());
drop policy if exists loans_delete on public.loans;
create policy loans_delete on public.loans for delete to authenticated using (public.is_management());

drop policy if exists loan_milestones_rw on public.loan_milestones;
create policy loan_milestones_rw on public.loan_milestones for all to authenticated
  using (public.can_access_loan(loan_id)) with check (public.can_access_loan(loan_id));

drop policy if exists loan_events_read on public.loan_events;
create policy loan_events_read on public.loan_events for select to authenticated
  using (public.can_access_loan(loan_id));
-- No insert/update/delete policies: history is trigger-written and immutable to app users.

revoke all on public.loan_events from anon;
revoke insert, update, delete on public.loan_events from authenticated;
revoke insert, update, delete on public.user_roles from authenticated;
revoke all on public.loans, public.loan_milestones, public.user_roles, public.processors from anon;
