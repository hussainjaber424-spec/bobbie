# Mortgage processing command center

Two deliverables live here.

## `app/index.html`: hosted version (live now)
A single-page app published on claude.ai with assignment-based access:
processors (shared as Contributor) see only their own loans; management
(Editor/Owner) sees the full pipeline, finance, payroll records and reports.

## `supabase/` + `src/lib/`: Lovable Cloud / TanStack version
- `supabase/migrations/`: additive schema for all three phases: roles kept
  apart from profiles, row-level security, milestone and activity triggers,
  tasks, conditions, private document storage, finance, contacts, reports.
- `src/lib/stages.ts`: shared stage module (funded/cancelled/denied are
  finished; on hold/restructured stay active).
- `src/lib/import/`: `.xlsx` importer: Loan Officer color -> processor
  (Purple Bobbie, Green Adel, Orange Katie, Yellow Moe); other colors are
  flagged for review; duplicate and missing-value preview.

**Before applying the migrations to an existing Lovable project:** they were
written without access to its current schema. If loans already live in a
table with another name or other column names, reconcile first, otherwise a
second, empty `loans` table is created alongside the real one.

### Tests
```bash
npm install
npm test          # stage module, color mapping, workbook preview
npm run test:db   # migrations + permission checks on local Postgres 16
```
