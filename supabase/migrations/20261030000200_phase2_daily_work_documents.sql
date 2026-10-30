-- Phase 2: daily work, conditions, required documents, private document storage.

-- ---------------------------------------------------------------------------
-- Tasks: every task belongs to a loan.
-- ---------------------------------------------------------------------------
create table if not exists public.loan_tasks (
  id           uuid primary key default gen_random_uuid(),
  loan_id      uuid not null references public.loans(id) on delete cascade,
  title        text not null check (length(trim(title)) between 1 and 300),
  details      text check (details is null or length(details) <= 5000),
  kind         text not null default 'task' check (kind in ('task', 'borrower_follow_up', 'lender_follow_up', 'title_follow_up')),
  assigned_to  uuid references public.processors(id),
  due_date     date,
  completed_at timestamptz,
  completed_by uuid references auth.users(id),
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists loan_tasks_loan_idx on public.loan_tasks (loan_id);
create index if not exists loan_tasks_open_idx on public.loan_tasks (assigned_to, due_date) where completed_at is null;

-- Conditions and required documents share one checklist table.
create table if not exists public.loan_requirements (
  id          uuid primary key default gen_random_uuid(),
  loan_id     uuid not null references public.loans(id) on delete cascade,
  kind        text not null check (kind in ('condition', 'document')),
  title       text not null check (length(trim(title)) between 1 and 300),
  status      text not null default 'outstanding' check (status in ('outstanding', 'received', 'cleared', 'waived')),
  due_date    date,
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id),
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists loan_requirements_loan_idx on public.loan_requirements (loan_id);

create table if not exists public.loan_documents (
  id             uuid primary key default gen_random_uuid(),
  loan_id        uuid not null references public.loans(id) on delete cascade,
  requirement_id uuid references public.loan_requirements(id) on delete set null,
  storage_path   text not null unique,
  file_name      text not null check (length(file_name) between 1 and 255),
  mime_type      text,
  size_bytes     bigint check (size_bytes is null or size_bytes between 0 and 52428800),
  uploaded_by    uuid references auth.users(id) default auth.uid(),
  uploaded_at    timestamptz not null default now(),
  -- Path must sit under the loan's own folder: <loan_id>/<anything>
  constraint loan_documents_path_in_loan check (split_part(storage_path, '/', 1) = loan_id::text)
);

create table if not exists public.loan_communications (
  id          uuid primary key default gen_random_uuid(),
  loan_id     uuid not null references public.loans(id) on delete cascade,
  channel     text not null default 'note' check (channel in ('note', 'call', 'email', 'text', 'meeting')),
  direction   text check (direction in ('inbound', 'outbound')),
  counterpart text check (counterpart is null or length(counterpart) <= 200),
  body        text not null check (length(trim(body)) between 1 and 20000),
  occurred_at timestamptz not null default now(),
  author_id   uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists loan_communications_loan_idx on public.loan_communications (loan_id, occurred_at);

-- In-app alerts. Scheduled delivery (email/SMS) is deferred until preferences are defined.
create table if not exists public.alerts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  loan_id    uuid references public.loans(id) on delete cascade,
  message    text not null,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists alerts_user_idx on public.alerts (user_id) where read_at is null;

-- ---------------------------------------------------------------------------
-- Stamping + history triggers
-- ---------------------------------------------------------------------------
create or replace function public.loan_tasks_before_write()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.loan_id is distinct from old.loan_id then
    raise exception 'A task cannot be moved to another loan';
  end if;
  if new.completed_at is not null and (tg_op = 'INSERT' or old.completed_at is null) then
    new.completed_by := auth.uid();
  elsif new.completed_at is null then
    new.completed_by := null;
  end if;
  return new;
end $$;
drop trigger if exists loan_tasks_before_write on public.loan_tasks;
create trigger loan_tasks_before_write before insert or update on public.loan_tasks
  for each row execute function public.loan_tasks_before_write();

create or replace function public.loan_tasks_after_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if tg_op = 'INSERT' then
    perform public.log_loan_event(new.loan_id, 'task_created', null, new.title, jsonb_build_object('task_id', new.id, 'due_date', new.due_date));
  elsif old.completed_at is null and new.completed_at is not null then
    perform public.log_loan_event(new.loan_id, 'task_completed', null, new.title, jsonb_build_object('task_id', new.id));
  elsif old.completed_at is not null and new.completed_at is null then
    perform public.log_loan_event(new.loan_id, 'task_reopened', null, new.title, jsonb_build_object('task_id', new.id));
  end if;
  if new.assigned_to is not null and (tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to) then
    select user_id into v_user from public.processors where id = new.assigned_to;
    if v_user is not null and v_user is distinct from auth.uid() then
      insert into public.alerts (user_id, loan_id, message) values (v_user, new.loan_id, 'New task assigned: ' || new.title);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists loan_tasks_after_write on public.loan_tasks;
create trigger loan_tasks_after_write after insert or update on public.loan_tasks
  for each row execute function public.loan_tasks_after_write();

create or replace function public.loan_requirements_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.resolved_at := case when new.status = 'outstanding' then null else now() end;
    new.resolved_by := case when new.status = 'outstanding' then null else auth.uid() end;
    perform public.log_loan_event(new.loan_id, new.kind || '_status', old.status, new.status, jsonb_build_object('requirement_id', new.id, 'title', new.title));
  elsif tg_op = 'INSERT' then
    perform public.log_loan_event(new.loan_id, new.kind || '_added', null, new.title, jsonb_build_object('requirement_id', new.id));
  end if;
  return new;
end $$;
drop trigger if exists loan_requirements_write on public.loan_requirements;
create trigger loan_requirements_write before insert or update on public.loan_requirements
  for each row execute function public.loan_requirements_write();

create or replace function public.loan_documents_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.log_loan_event(new.loan_id, 'document_uploaded', null, new.file_name, jsonb_build_object('document_id', new.id));
  if new.requirement_id is not null then
    update public.loan_requirements set status = 'received'
     where id = new.requirement_id and loan_id = new.loan_id and status = 'outstanding';
  end if;
  return null;
end $$;
drop trigger if exists loan_documents_after_insert on public.loan_documents;
create trigger loan_documents_after_insert after insert on public.loan_documents
  for each row execute function public.loan_documents_after_insert();

create or replace function public.loan_communications_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.log_loan_event(new.loan_id, 'communication_' || new.channel, null, left(new.body, 120), jsonb_build_object('communication_id', new.id));
  return null;
end $$;
drop trigger if exists loan_communications_after_insert on public.loan_communications;
create trigger loan_communications_after_insert after insert on public.loan_communications
  for each row execute function public.loan_communications_after_insert();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.loan_tasks          enable row level security;
alter table public.loan_requirements   enable row level security;
alter table public.loan_documents      enable row level security;
alter table public.loan_communications enable row level security;
alter table public.alerts              enable row level security;

drop policy if exists loan_tasks_rw on public.loan_tasks;
create policy loan_tasks_rw on public.loan_tasks for all to authenticated
  using (public.can_access_loan(loan_id)) with check (public.can_access_loan(loan_id));

drop policy if exists loan_requirements_rw on public.loan_requirements;
create policy loan_requirements_rw on public.loan_requirements for all to authenticated
  using (public.can_access_loan(loan_id)) with check (public.can_access_loan(loan_id));

drop policy if exists loan_documents_read on public.loan_documents;
create policy loan_documents_read on public.loan_documents for select to authenticated using (public.can_access_loan(loan_id));
drop policy if exists loan_documents_insert on public.loan_documents;
create policy loan_documents_insert on public.loan_documents for insert to authenticated with check (public.can_access_loan(loan_id));
drop policy if exists loan_documents_delete on public.loan_documents;
create policy loan_documents_delete on public.loan_documents for delete to authenticated using (public.is_management());

drop policy if exists loan_communications_read on public.loan_communications;
create policy loan_communications_read on public.loan_communications for select to authenticated using (public.can_access_loan(loan_id));
drop policy if exists loan_communications_insert on public.loan_communications;
create policy loan_communications_insert on public.loan_communications for insert to authenticated
  with check (public.can_access_loan(loan_id) and author_id = auth.uid());

drop policy if exists alerts_own on public.alerts;
create policy alerts_own on public.alerts for select to authenticated using (user_id = auth.uid());
drop policy if exists alerts_mark_read on public.alerts;
create policy alerts_mark_read on public.alerts for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.loan_tasks, public.loan_requirements, public.loan_documents, public.loan_communications, public.alerts from anon;

-- ---------------------------------------------------------------------------
-- Private storage. Files live at loan-documents/<loan_id>/<uuid>-<filename>.
-- Downloads go through short-lived signed URLs, which Storage only issues to
-- users who pass the select policy below. Never use getPublicUrl for this bucket.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('loan-documents', 'loan-documents', false, 52428800)
on conflict (id) do update set public = false;

create or replace function public.storage_loan_id(p_name text)
returns uuid language plpgsql immutable as $$
begin
  return split_part(p_name, '/', 1)::uuid;
exception when others then return null;
end $$;

drop policy if exists loan_docs_read on storage.objects;
create policy loan_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'loan-documents' and public.can_access_loan(public.storage_loan_id(name)));
drop policy if exists loan_docs_upload on storage.objects;
create policy loan_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'loan-documents' and public.can_access_loan(public.storage_loan_id(name)));
drop policy if exists loan_docs_delete on storage.objects;
create policy loan_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'loan-documents' and public.is_management());

-- ---------------------------------------------------------------------------
-- Daily work dashboard. security_invoker so RLS limits processors to their loans.
-- ---------------------------------------------------------------------------
create or replace view public.work_items with (security_invoker = true) as
  select 'task_overdue'::text as item_type, t.loan_id, l.processor_id, l.borrower_name,
         t.id as ref_id, t.title, t.due_date, 1 as severity
    from public.loan_tasks t join public.loans l on l.id = t.loan_id
   where t.completed_at is null and t.due_date < current_date
  union all
  select case when t.kind = 'borrower_follow_up' then 'borrower_follow_up' else 'task_due' end,
         t.loan_id, l.processor_id, l.borrower_name, t.id, t.title, t.due_date, 2
    from public.loan_tasks t join public.loans l on l.id = t.loan_id
   where t.completed_at is null and (t.due_date is null or t.due_date >= current_date)
     and (t.kind = 'borrower_follow_up' or t.due_date <= current_date + 2)
  union all
  select case r.kind when 'condition' then 'condition_outstanding' else 'document_missing' end,
         r.loan_id, l.processor_id, l.borrower_name, r.id, r.title, r.due_date,
         case when r.due_date < current_date then 1 else 2 end
    from public.loan_requirements r join public.loans l on l.id = r.loan_id
   where r.status = 'outstanding' and not (select is_finished from public.loan_stages where key = l.stage)
  union all
  select 'closing_upcoming', l.id, l.processor_id, l.borrower_name, l.id, 'Closing ' || to_char(l.closing_date, 'Mon DD'), l.closing_date, 2
    from public.loans l
   where l.closing_date between current_date and current_date + 7
     and not (select is_finished from public.loan_stages where key = l.stage)
  union all
  select 'rate_lock_expiring', l.id, l.processor_id, l.borrower_name, l.id, 'Rate lock expires ' || to_char(l.rate_lock_expires, 'Mon DD'), l.rate_lock_expires,
         case when l.rate_lock_expires < current_date then 1 else 2 end
    from public.loans l
   where l.rate_lock_expires <= current_date + 5
     and not (select is_finished from public.loan_stages where key = l.stage);
