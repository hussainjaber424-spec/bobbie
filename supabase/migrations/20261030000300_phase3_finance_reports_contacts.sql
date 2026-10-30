-- Phase 3: finance (management only), payroll records, contacts, reports.
-- Payroll here is record-keeping only: no payments are made and no taxes are calculated.

-- ---------------------------------------------------------------------------
-- Contacts: shared directory, readable by all staff.
-- ---------------------------------------------------------------------------
create table if not exists public.contacts (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (category in ('lender', 'title', 'insurance', 'appraiser', 'attorney', 'realtor', 'other')),
  company    text check (company is null or length(company) <= 200),
  name       text check (name is null or length(name) <= 200),
  email      text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone      text check (phone is null or length(phone) <= 40),
  notes      text check (notes is null or length(notes) <= 5000),
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  search     tsvector generated always as (
    to_tsvector('simple', coalesce(company, '') || ' ' || coalesce(name, '') || ' ' || coalesce(email, '') || ' ' || coalesce(phone, '') || ' ' || category)
  ) stored,
  constraint contacts_has_identity check (company is not null or name is not null)
);
create index if not exists contacts_search_idx on public.contacts using gin (search);

alter table public.contacts enable row level security;
drop policy if exists contacts_read on public.contacts;
create policy contacts_read on public.contacts for select to authenticated
  using (public.is_management() or public.my_processor_id() is not null);
drop policy if exists contacts_write on public.contacts;
create policy contacts_write on public.contacts for insert to authenticated
  with check (public.is_management() or public.my_processor_id() is not null);
drop policy if exists contacts_update on public.contacts;
create policy contacts_update on public.contacts for update to authenticated
  using (public.is_management() or public.my_processor_id() is not null)
  with check (public.is_management() or public.my_processor_id() is not null);
drop policy if exists contacts_delete on public.contacts;
create policy contacts_delete on public.contacts for delete to authenticated using (public.is_management());

-- ---------------------------------------------------------------------------
-- Finance: management only.
-- ---------------------------------------------------------------------------
create table if not exists public.invoices (
  id             uuid primary key default gen_random_uuid(),
  invoice_number text not null unique check (length(trim(invoice_number)) between 1 and 50),
  loan_id        uuid references public.loans(id) on delete restrict,
  bill_to        text check (bill_to is null or length(bill_to) <= 200),
  issued_on      date not null default current_date,
  due_on         date,
  processing_fee numeric(12,2) not null default 0 check (processing_fee >= 0),
  other_fees     numeric(12,2) not null default 0 check (other_fees >= 0),
  total          numeric(12,2) generated always as (processing_fee + other_fees) stored,
  status         text not null default 'draft' check (status in ('draft', 'sent', 'void')),
  notes          text,
  created_by     uuid references auth.users(id) default auth.uid(),
  created_at     timestamptz not null default now()
);

create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete restrict,
  amount      numeric(12,2) not null check (amount > 0),
  received_on date not null default current_date,
  method      text check (method in ('check', 'ach', 'wire', 'card', 'other')),
  reference   text check (reference is null or length(reference) <= 100),
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists payments_invoice_idx on public.payments (invoice_id);

create table if not exists public.payroll_records (
  id           uuid primary key default gen_random_uuid(),
  processor_id uuid not null references public.processors(id),
  period_start date not null,
  period_end   date not null,
  loan_id      uuid references public.loans(id) on delete set null,
  basis        text not null check (basis in ('per_file', 'hourly', 'salary', 'bonus', 'adjustment')),
  quantity     numeric(10,2),
  rate         numeric(12,2),
  amount       numeric(12,2) not null,
  status       text not null default 'recorded' check (status in ('recorded', 'approved')),
  notes        text,
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  constraint payroll_period_valid check (period_end >= period_start)
);

alter table public.invoices        enable row level security;
alter table public.payments        enable row level security;
alter table public.payroll_records enable row level security;

drop policy if exists invoices_mgmt on public.invoices;
create policy invoices_mgmt on public.invoices for all to authenticated
  using (public.is_management()) with check (public.is_management());
drop policy if exists payments_mgmt on public.payments;
create policy payments_mgmt on public.payments for all to authenticated
  using (public.is_management()) with check (public.is_management());
drop policy if exists payroll_mgmt on public.payroll_records;
create policy payroll_mgmt on public.payroll_records for all to authenticated
  using (public.is_management()) with check (public.is_management());

revoke all on public.invoices, public.payments, public.payroll_records, public.contacts from anon;

-- Receivables computed from recorded invoices and payments only.
create or replace view public.receivables with (security_invoker = true) as
  select i.id as invoice_id, i.invoice_number, i.loan_id, l.borrower_name, i.bill_to,
         i.issued_on, i.due_on, i.total,
         coalesce(sum(p.amount), 0)::numeric(12,2) as paid,
         (i.total - coalesce(sum(p.amount), 0))::numeric(12,2) as balance,
         case when i.total - coalesce(sum(p.amount), 0) <= 0 then 'paid'
              when i.due_on < current_date then 'overdue'
              else 'open' end as receivable_status
    from public.invoices i
    left join public.payments p on p.invoice_id = i.id
    left join public.loans l on l.id = i.loan_id
   where i.status <> 'void' and public.is_management()
   group by i.id, l.borrower_name;

create or replace view public.funded_loans with (security_invoker = true) as
  select l.id as loan_id, l.loan_number, l.borrower_name, l.loan_officer, l.processor_id, p.name as processor,
         l.loan_amount, l.lender_name, l.funding_date,
         m.completed_at as funding_recorded_at,
         coalesce((select sum(i.total) from public.invoices i where i.loan_id = l.id and i.status <> 'void'), 0) as invoiced
    from public.loans l
    left join public.processors p on p.id = l.processor_id
    left join public.loan_milestones m on m.loan_id = l.id and m.milestone = 'funding' and m.completed_at is not null
   where l.stage = 'funded' and public.is_management();

-- ---------------------------------------------------------------------------
-- Reports: derived from recorded milestones/events/invoices. Management only.
-- ---------------------------------------------------------------------------
create or replace view public.report_processor_workload with (security_invoker = true) as
  select p.id as processor_id, p.name,
         count(l.id) filter (where not s.is_finished) as open_loans,
         count(l.id) filter (where l.stage in ('on_hold', 'restructured')) as held_or_restructured,
         count(l.id) filter (where l.closing_date between current_date and current_date + 14 and not s.is_finished) as closing_next_14_days,
         (select count(*) from public.loan_tasks t where t.assigned_to = p.id and t.completed_at is null and t.due_date < current_date) as overdue_tasks
    from public.processors p
    left join public.loans l on l.processor_id = p.id
    left join public.loan_stages s on s.key = l.stage
   where public.is_management()
   group by p.id, p.name;

create or replace view public.report_monthly_milestones with (security_invoker = true) as
  select date_trunc('month', m.completed_at)::date as month,
         count(*) filter (where m.milestone = 'clear_to_close') as clear_to_close_count,
         count(*) filter (where m.milestone = 'funding') as funded_count,
         count(*) filter (where m.milestone = 'submission') as submitted_count
    from public.loan_milestones m
   where m.completed_at is not null and public.is_management()
   group by 1;

-- Turnaround in days between recorded milestones. Null when a milestone was never recorded.
create or replace view public.report_turnaround with (security_invoker = true) as
  select l.id as loan_id, l.borrower_name, l.processor_id, l.loan_officer,
         sub.completed_at as submitted_at, ctc.completed_at as clear_to_close_at, fund.completed_at as funded_at,
         round(extract(epoch from (ctc.completed_at - sub.completed_at)) / 86400.0, 1) as days_submission_to_ctc,
         round(extract(epoch from (fund.completed_at - sub.completed_at)) / 86400.0, 1) as days_submission_to_funded
    from public.loans l
    left join public.loan_milestones sub  on sub.loan_id  = l.id and sub.milestone  = 'submission'     and sub.completed_at  is not null
    left join public.loan_milestones ctc  on ctc.loan_id  = l.id and ctc.milestone  = 'clear_to_close' and ctc.completed_at  is not null
    left join public.loan_milestones fund on fund.loan_id = l.id and fund.milestone = 'funding'        and fund.completed_at is not null
   where public.is_management();

create or replace view public.report_monthly_fees with (security_invoker = true) as
  with inv as (
    select date_trunc('month', issued_on)::date as month, count(*) as invoices,
           sum(processing_fee) as processing_fees, sum(total) as invoiced_total
      from public.invoices where status <> 'void' group by 1
  ), pay as (
    select date_trunc('month', received_on)::date as month, sum(amount) as collected
      from public.payments group by 1
  )
  select coalesce(inv.month, pay.month) as month,
         coalesce(inv.invoices, 0) as invoices,
         coalesce(inv.processing_fees, 0) as processing_fees,
         coalesce(inv.invoiced_total, 0) as invoiced_total,
         coalesce(pay.collected, 0) as collected_in_month
    from inv full join pay on pay.month = inv.month
   where public.is_management();
