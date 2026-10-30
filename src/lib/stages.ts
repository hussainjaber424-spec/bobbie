// Shared stage module. Single source of truth for loan stages, milestones and
// open/finished classification. The SQL seed in
// supabase/migrations/20261030000100_phase1_secure_loans.sql mirrors these
// definitions; src/lib/__tests__/stages.test.ts fails if the two drift apart.
//
// When merging into the existing app, fold these definitions into the existing
// stage module rather than keeping two copies.

export const PIPELINE_STAGES = [
  { key: "application", label: "Application", tone: "slate" },
  { key: "submitted", label: "Submitted", tone: "blue" },
  { key: "esigned", label: "E-signed", tone: "blue" },
  { key: "documents_received", label: "Documents received", tone: "indigo" },
  { key: "rate_locked", label: "Rate locked", tone: "indigo" },
  { key: "underwriting", label: "Underwriting", tone: "amber" },
  { key: "approved", label: "Approved", tone: "teal" },
  { key: "clear_to_close", label: "Clear to close", tone: "green" },
  { key: "closing", label: "Closing", tone: "green" },
  { key: "funded", label: "Funded", tone: "emerald" },
] as const;

export const EXCEPTION_STAGES = [
  { key: "on_hold", label: "On hold", tone: "orange" },
  { key: "restructured", label: "Restructured", tone: "purple" },
  { key: "denied", label: "Denied", tone: "red" },
  { key: "cancelled", label: "Cancelled", tone: "gray" },
] as const;

export type PipelineStage = (typeof PIPELINE_STAGES)[number]["key"];
export type ExceptionStage = (typeof EXCEPTION_STAGES)[number]["key"];
export type LoanStage = PipelineStage | ExceptionStage;

export const ALL_STAGES = [...PIPELINE_STAGES, ...EXCEPTION_STAGES];

/** Funded, cancelled and denied are finished. On hold and restructured stay active. */
export const FINISHED_STAGES: ReadonlySet<LoanStage> = new Set(["funded", "cancelled", "denied"]);

export function isFinished(stage: LoanStage): boolean {
  return FINISHED_STAGES.has(stage);
}

export function isOpen(stage: LoanStage): boolean {
  return !isFinished(stage);
}

export function isPipelineStage(stage: string): stage is PipelineStage {
  return PIPELINE_STAGES.some((s) => s.key === stage);
}

/** 0-based position in the pipeline, or -1 for exception stages. */
export function stagePosition(stage: LoanStage): number {
  return PIPELINE_STAGES.findIndex((s) => s.key === stage);
}

export function stageLabel(stage: LoanStage): string {
  return ALL_STAGES.find((s) => s.key === stage)?.label ?? stage;
}

export function stageTone(stage: LoanStage): string {
  return ALL_STAGES.find((s) => s.key === stage)?.tone ?? "slate";
}

// Each milestone moves a loan into one pipeline stage when completed.
export const MILESTONES = [
  { key: "submission", label: "Submission", stage: "submitted" },
  { key: "esign", label: "E-signing", stage: "esigned" },
  { key: "documents", label: "Documents received", stage: "documents_received" },
  { key: "rate_lock", label: "Rate lock", stage: "rate_locked" },
  { key: "underwriting", label: "Underwriting", stage: "underwriting" },
  { key: "approval", label: "Approval", stage: "approved" },
  { key: "clear_to_close", label: "Clear to close", stage: "clear_to_close" },
  { key: "closing", label: "Closing", stage: "closing" },
  { key: "funding", label: "Funding", stage: "funded" },
] as const satisfies readonly { key: string; label: string; stage: PipelineStage }[];

export type Milestone = (typeof MILESTONES)[number]["key"];

export function milestoneStage(m: Milestone): PipelineStage {
  return MILESTONES.find((x) => x.key === m)!.stage;
}

/**
 * Stage a loan should be in after `milestone` is completed. Mirrors the
 * database trigger `loan_milestones_sync_stage`, which is authoritative.
 * - Finished loans reject milestone changes (the database raises).
 * - On hold / restructured loans keep their stage; the milestone is still recorded.
 * - Otherwise the loan only moves forward, never backward.
 */
export function stageAfterMilestone(current: LoanStage, milestone: Milestone): LoanStage {
  if (isFinished(current)) throw new Error(`Loan is ${current}; milestones cannot change.`);
  if (!isPipelineStage(current)) return current;
  const target = milestoneStage(milestone);
  return stagePosition(target) > stagePosition(current) ? target : current;
}

export interface Requirement {
  status: "outstanding" | "received" | "cleared" | "waived";
}

/** Checklist progress from completed milestones plus satisfied conditions/documents. */
export function loanProgress(completed: Iterable<Milestone>, requirements: Requirement[] = []) {
  const done = new Set(completed);
  const milestonesDone = MILESTONES.filter((m) => done.has(m.key)).length;
  const reqDone = requirements.filter((r) => r.status !== "outstanding").length;
  const total = MILESTONES.length + requirements.length;
  const complete = milestonesDone + reqDone;
  return {
    milestonesDone,
    milestonesTotal: MILESTONES.length,
    requirementsDone: reqDone,
    requirementsTotal: requirements.length,
    percent: total === 0 ? 0 : Math.round((complete / total) * 100),
  };
}
