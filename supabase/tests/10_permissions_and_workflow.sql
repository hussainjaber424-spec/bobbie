-- End-to-end checks for access rules and loan workflow, run against the
-- migrations on local Postgres with the Supabase shim. Any failed assertion aborts.
\set ON_ERROR_STOP on
set client_min_messages = warning;

create schema if not exists t;
create or replace function t.login(p_email text) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', false);
  perform set_config('request.jwt.claim.sub', (select id::text from auth.users where email = p_email), false);
end $$;
create or replace function t.expect_error(p_sql text, p_label text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise warning 'blocked: % -> %', p_label, sqlerrm; return; end;
  raise exception 'EXPECTED FAILURE but succeeded: %', p_label;
end $$;
grant usage on schema t to authenticated;
grant execute on all functions in schema t to authenticated;

insert into auth.users (email) values ('mgmt@co.test'), ('bobbie@co.test'), ('adel@co.test'), ('newbie@co.test');

-- Bootstrap is service-role only.
select t.login('newbie@co.test');
select t.expect_error($$select public.bootstrap_management('newbie@co.test')$$, 'app user cannot bootstrap management');
reset role;
select public.bootstrap_management('mgmt@co.test');

-- New account: no role, no data, no write.
select t.login('newbie@co.test');
do $$ begin
  assert not public.is_management(), 'new account must not be management';
  assert public.my_processor_id() is null, 'new account must not be a processor';
end $$;
select t.expect_error($$insert into public.loans (borrower_name) values ('X')$$, 'unassigned account cannot create loans');
select t.expect_error($$insert into public.user_roles (user_id, role) select id, 'management' from auth.users where email = 'newbie@co.test'$$, 'cannot self-grant management');
select t.expect_error($$select public.set_user_role((select id from auth.users where email='newbie@co.test'), 'management', true)$$, 'non-management cannot set roles');

-- Management links accounts.
select t.login('mgmt@co.test');
select public.link_processor_account((select id from public.processors where name = 'Bobbie'), (select id from auth.users where email = 'bobbie@co.test'));
select public.link_processor_account((select id from public.processors where name = 'Adel'),   (select id from auth.users where email = 'adel@co.test'));
insert into public.loans (borrower_name, loan_number, loan_officer, processor_id, property_address)
values ('Adel Borrower', 'LN-ADEL-1', 'Sam LO', (select id from public.processors where name = 'Adel'), '9 Elm St');
reset role;
create table t.ids as select loan_number, id from public.loans;
grant select on t.ids to authenticated;

-- Processor creates and works a loan.
select t.login('bobbie@co.test');
insert into public.loans (borrower_name, loan_number, loan_officer, property_address, closing_date, rate_lock_expires)
values ('Jane Doe', 'LN-1001', 'Sam LO', '1 Main St', current_date + 3, current_date + 2);
reset role;
insert into t.ids select loan_number, id from public.loans where loan_number = 'LN-1001';
select t.login('bobbie@co.test');
select t.expect_error($$insert into public.loans (borrower_name, processor_id) values ('Y', (select id from public.processors where name='Adel'))$$, 'processor cannot create loan for someone else');
select t.expect_error($$update public.loans set processor_id = (select id from public.processors where name='Adel') where loan_number = 'LN-1001'$$, 'processor cannot reassign');

do $$
declare v uuid := (select id from public.loans where loan_number = 'LN-1001');
        me uuid := auth.uid();
        r record;
begin
  assert (select count(*) from public.loans) = 1, 'Bobbie must see only her loan';
  assert (select processor_id from public.loans where id = v) = public.my_processor_id(), 'loan defaults to creator';

  perform public.complete_milestone(v, 'approval');
  select * into r from public.loan_milestones where loan_id = v and milestone = 'approval';
  assert r.completed_at::date = current_date, 'approval date recorded automatically';
  assert r.completed_by = me, 'approval records who completed it';
  assert (select stage from public.loans where id = v) = 'approved', 'approval moves stage to approved';
  assert exists (select 1 from public.loan_events where loan_id = v and event_type = 'stage_changed'
                 and from_value = 'application' and to_value = 'approved' and actor_id = me), 'stage change logged with actor';

  perform public.complete_milestone(v, 'submission');
  assert (select stage from public.loans where id = v) = 'approved', 'earlier milestone does not move stage backward';

  perform public.complete_milestone(v, 'approval');  -- second click is a no-op
  assert (select count(*) from public.loan_events where loan_id = v and event_type = 'milestone_completed' and to_value = 'approval') = 1, 'double click does not duplicate';

  perform public.reopen_milestone(v, 'approval');
  assert (select stage from public.loans where id = v) = 'submitted', 'reopening falls back to highest remaining milestone';
  assert (select completed_at from public.loan_milestones where loan_id = v and milestone = 'approval') is null, 'reopened milestone cleared';

  -- Stage set directly (outside the milestone button) still records the milestone.
  update public.loans set stage = 'clear_to_close' where id = v;
  assert (select completed_at from public.loan_milestones where loan_id = v and milestone = 'clear_to_close') is not null, 'direct stage edit stamps milestone';

  update public.loans set stage = 'on_hold' where id = v;
  perform public.complete_milestone(v, 'closing');
  assert (select stage from public.loans where id = v) = 'on_hold', 'on hold keeps stage';
  assert (select completed_at from public.loan_milestones where loan_id = v and milestone = 'closing') is not null, 'milestone still recorded while on hold';

  assert (select count(*) from public.loan_events where loan_id = v and event_type = 'stage_changed') = 4, 'all stage changes retained';
end $$;

select t.expect_error($$delete from public.loan_events$$, 'history cannot be deleted');
select t.expect_error($$update public.loan_events set to_value = 'x'$$, 'history cannot be edited');
select t.expect_error($$insert into public.loan_events (loan_id, event_type) select id, 'fake' from public.loans limit 1$$, 'history cannot be forged');

-- Tasks, requirements, documents.
do $$
declare v uuid := (select id from public.loans where loan_number = 'LN-1001');
        tid uuid; rid uuid;
begin
  insert into public.loan_tasks (loan_id, title, due_date, assigned_to) values (v, 'Order appraisal', current_date - 1, public.my_processor_id()) returning id into tid;
  insert into public.loan_tasks (loan_id, title, kind) values (v, 'Call borrower re: bank statements', 'borrower_follow_up');
  insert into public.loan_requirements (loan_id, kind, title) values (v, 'document', 'Two months bank statements') returning id into rid;
  insert into public.loan_requirements (loan_id, kind, title) values (v, 'condition', 'Verify employment');

  assert exists (select 1 from public.work_items where item_type = 'task_overdue' and ref_id = tid), 'overdue task on dashboard';
  assert exists (select 1 from public.work_items where item_type = 'borrower_follow_up'), 'follow-up on dashboard';
  assert exists (select 1 from public.work_items where item_type = 'document_missing'), 'missing document on dashboard';
  assert exists (select 1 from public.work_items where item_type = 'condition_outstanding'), 'condition on dashboard';
  assert exists (select 1 from public.work_items where item_type = 'closing_upcoming'), 'upcoming closing on dashboard';
  assert exists (select 1 from public.work_items where item_type = 'rate_lock_expiring'), 'rate lock on dashboard';

  update public.loan_tasks set completed_at = now() where id = tid;
  assert (select completed_by from public.loan_tasks where id = tid) = auth.uid(), 'task completion records who';
  assert not exists (select 1 from public.work_items where ref_id = tid), 'completed task leaves dashboard';
  update public.loan_tasks set completed_at = null where id = tid;
  assert (select completed_by from public.loan_tasks where id = tid) is null, 'reopen clears completer';
  assert (select count(*) from public.loan_events where loan_id = v and event_type in ('task_completed', 'task_reopened')) = 2, 'task history logged';

  insert into storage.objects (bucket_id, name) values ('loan-documents', v::text || '/a1-bank.pdf');
  insert into public.loan_documents (loan_id, requirement_id, storage_path, file_name, size_bytes)
  values (v, rid, v::text || '/a1-bank.pdf', 'bank.pdf', 1024);
  assert (select status from public.loan_requirements where id = rid) = 'received', 'upload marks document received';
  assert (select count(*) from storage.objects) = 1, 'uploader can read own file';
end $$;
select t.expect_error($$insert into storage.objects (bucket_id, name) select 'loan-documents', id::text || '/x.pdf' from t.ids where loan_number = 'LN-ADEL-1'$$, 'cannot upload to another processor''s loan');
select t.expect_error($$insert into public.loan_documents (loan_id, storage_path, file_name) select id, gen_random_uuid()::text || '/x.pdf', 'x' from public.loans where loan_number='LN-1001'$$, 'document path must be in loan folder');

-- Processor cannot see finance.
do $$ begin
  assert (select count(*) from public.receivables) = 0, 'processor sees no receivables';
  assert (select count(*) from public.report_processor_workload) = 0, 'processor sees no reports';
end $$;
select t.expect_error($$insert into public.invoices (invoice_number, processing_fee) values ('INV-X', 1)$$, 'processor cannot create invoices');
select t.expect_error($$insert into public.payroll_records (processor_id, period_start, period_end, basis, amount) values (public.my_processor_id(), current_date, current_date, 'bonus', 1000)$$, 'processor cannot write payroll');

-- Another processor sees nothing of Bobbie's.
select t.login('adel@co.test');
do $$
declare n int;
begin
  assert (select count(*) from public.loans) = 1, 'Adel sees only her loan';
  assert not exists (select 1 from public.loans where loan_number = 'LN-1001'), 'Adel cannot see Bobbie loan';
  assert (select count(*) from public.loan_events l join public.loans x on x.id = l.loan_id where x.loan_number = 'LN-1001') = 0, 'no events';
  assert (select count(*) from public.loan_tasks) = 0, 'no tasks';
  assert (select count(*) from public.loan_documents) = 0, 'no document rows';
  assert (select count(*) from storage.objects) = 0, 'no file download';
  assert (select count(*) from public.work_items where borrower_name = 'Jane Doe') = 0, 'no dashboard leak';
  update public.loans set notes = 'hijack' where id = (select id from t.ids where loan_number = 'LN-1001');
  get diagnostics n = row_count;
  assert n = 0, 'cannot update Bobbie loan';
end $$;
select t.expect_error($$select public.complete_milestone((select id from t.ids where loan_number='LN-1001'), 'funding')$$, 'cannot complete milestone on another loan');

-- Management: whole pipeline, finance totals from recorded entries.
select t.login('mgmt@co.test');
do $$
declare v uuid := (select id from public.loans where loan_number = 'LN-1001');
        inv uuid;
begin
  assert (select count(*) from public.loans) = 2, 'management sees all loans';
  update public.loans set stage = 'funded', funding_date = current_date where id = v;
  begin
    perform public.complete_milestone(v, 'rate_lock');
    raise exception 'finished loan accepted a milestone';
  exception when raise_exception then
    if sqlerrm like 'finished loan accepted%' then raise; end if;
  end;

  insert into public.invoices (invoice_number, loan_id, processing_fee, other_fees, due_on) values ('INV-1', v, 495, 55, current_date - 1) returning id into inv;
  insert into public.payments (invoice_id, amount) values (inv, 200);
  assert (select balance from public.receivables where invoice_id = inv) = 350, 'receivable balance from records';
  assert (select receivable_status from public.receivables where invoice_id = inv) = 'overdue', 'overdue receivable';
  assert (select invoiced from public.funded_loans where loan_id = v) = 550, 'funded loan invoiced total';
  assert (select funded_count from public.report_monthly_milestones where month = date_trunc('month', current_date)::date) = 1, 'monthly funded count';
  assert (select clear_to_close_count from public.report_monthly_milestones where month = date_trunc('month', current_date)::date) = 1, 'monthly ctc count';
  assert (select open_loans from public.report_processor_workload where name = 'Adel') = 1, 'workload';
  assert (select days_submission_to_funded from public.report_turnaround where loan_id = v) is not null, 'turnaround computed';

  -- Imported loan arriving already funded.
  insert into public.loans (borrower_name, stage, processor_id) values ('Imported Funded', 'funded', (select id from public.processors where name = 'Adel'));

  insert into public.contacts (category, company, name, email) values ('title', 'Lakeside Title', 'Pat Closer', 'pat@lakeside.test');
end $$;

select t.login('bobbie@co.test');
do $$ begin
  assert (select count(*) from public.contacts where search @@ plainto_tsquery('simple', 'lakeside')) = 1, 'processor can search contacts';
end $$;
do $$ declare n int; begin
  delete from public.contacts; get diagnostics n = row_count;
  assert n = 0, 'processor cannot delete contacts';
end $$;
reset role;
select 'ALL DATABASE CHECKS PASSED' as result;
