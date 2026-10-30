// Reads a loan tracker .xlsx and produces an import preview: column mapping,
// processor assignment from Loan Officer cell color, missing values and likely
// duplicates. Nothing is written; the app commits only rows management approves.
import ExcelJS from "exceljs";
import { classifyColor, parseThemePalette, resolveThemeColor, type ColorMatch } from "./colors";
import { ALL_STAGES, type LoanStage } from "../stages";

const FIELD_SYNONYMS: Record<string, string[]> = {
  borrower_name: ["borrower", "borrower name", "client", "name"],
  loan_number: ["loan #", "loan number", "loan no", "loan no.", "loan num"],
  loan_officer: ["loan officer", "lo"],
  property_address: ["property", "property address", "address", "subject property"],
  lender_name: ["lender"],
  loan_amount: ["loan amount", "amount"],
  stage: ["status", "stage"],
  application_date: ["app date", "application date", "date"],
  closing_date: ["closing", "closing date", "close date", "coe"],
  funding_date: ["funding", "funding date", "funded", "fund date"],
  notes: ["notes", "comments"],
};

const STAGE_SYNONYMS: Record<string, LoanStage> = {
  ctc: "clear_to_close", "clear to close": "clear_to_close", closed: "closing", hold: "on_hold",
  "on hold": "on_hold", "in uw": "underwriting", uw: "underwriting", locked: "rate_locked",
  canceled: "cancelled", withdrawn: "cancelled", declined: "denied", new: "application",
};

export interface PreviewRow {
  sheet: string;
  rowNumber: number;
  values: Record<string, string | number | Date | null>;
  processor: ColorMatch;
  stage: LoanStage | null;
  issues: string[];
  duplicateOf: string | null;
}

export interface ImportPreview {
  columnMap: Record<string, string>; // field -> header text found
  unmappedHeaders: string[];
  rows: PreviewRow[];
  summary: { total: number; assigned: number; needsColorReview: number; withIssues: number; duplicates: number };
}

export interface ExistingLoan {
  id: string;
  loan_number: string | null;
  borrower_name: string | null;
  property_address: string | null;
}

const norm = (s: unknown) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");

function cellValue(v: ExcelJS.CellValue): string | number | Date | null {
  if (v == null) return null;
  if (v instanceof Date || typeof v === "number") return v;
  if (typeof v === "object") {
    if ("result" in v) return cellValue(v.result as ExcelJS.CellValue);
    if ("richText" in v) return v.richText.map((t) => t.text).join("");
    if ("text" in v) return String(v.text);
  }
  const s = String(v).trim();
  return s === "" ? null : s;
}

function fillHex(cell: ExcelJS.Cell, theme: string[]): string | null {
  const fill = cell.fill as ExcelJS.FillPattern | undefined;
  if (!fill || fill.type !== "pattern" || fill.pattern === "none") return null;
  const c = (fill.fgColor ?? fill.bgColor) as { argb?: string; theme?: number; tint?: number } | undefined;
  if (!c) return null;
  if (c.argb) return c.argb;
  if (c.theme != null) return resolveThemeColor(theme, c.theme, c.tint ?? 0);
  return null;
}

function parseStage(v: unknown): LoanStage | null {
  const s = String(v ?? "").trim().toLowerCase();
  if (!s) return null;
  const direct = ALL_STAGES.find((x) => x.key === s.replace(/ /g, "_") || x.label.toLowerCase() === s);
  return direct?.key ?? STAGE_SYNONYMS[s] ?? null;
}

export async function previewWorkbook(data: ArrayBuffer | Buffer, existing: ExistingLoan[] = []): Promise<ImportPreview> {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(data as ArrayBuffer);
  const themes = (wb as unknown as { _themes?: Record<string, string> })._themes;
  const palette = parseThemePalette(themes?.theme1);

  const byNumber = new Map(existing.filter((e) => e.loan_number).map((e) => [norm(e.loan_number), e.id]));
  const byPerson = new Map(existing.map((e) => [norm(e.borrower_name) + "|" + norm(e.property_address), e.id]));

  const rows: PreviewRow[] = [];
  const columnMap: Record<string, string> = {};
  const unmapped = new Set<string>();

  for (const ws of wb.worksheets) {
    // Header row = first row within the top 10 that has a Loan Officer column.
    let headerRow = 0;
    const cols: Record<string, number> = {};
    for (let r = 1; r <= Math.min(10, ws.rowCount) && !headerRow; r++) {
      const headers: [number, string][] = [];
      ws.getRow(r).eachCell((c, col) => headers.push([col, String(cellValue(c.value) ?? "").trim()]));
      if (!headers.some(([, h]) => FIELD_SYNONYMS.loan_officer.includes(h.toLowerCase()))) continue;
      headerRow = r;
      for (const [col, h] of headers) {
        const field = Object.entries(FIELD_SYNONYMS).find(([f, syn]) => !cols[f] && syn.includes(h.toLowerCase()))?.[0];
        if (field) { cols[field] = col; columnMap[field] = h; } else if (h) unmapped.add(h);
      }
    }
    if (!headerRow) continue;

    for (let r = headerRow + 1; r <= ws.rowCount; r++) {
      const row = ws.getRow(r);
      const values: PreviewRow["values"] = {};
      for (const [f, col] of Object.entries(cols)) values[f] = cellValue(row.getCell(col).value);
      if (Object.values(values).every((v) => v == null)) continue;

      const issues: string[] = [];
      if (!values.borrower_name) issues.push("Missing borrower name");
      if (!values.loan_number) issues.push("Missing loan number");
      if (!values.loan_officer) issues.push("Missing loan officer");

      const processor = classifyColor(fillHex(row.getCell(cols.loan_officer), palette));
      if (processor.status === "review") issues.push(`Processor needs review: ${processor.reason}`);
      else if (processor.confidence === "inferred") issues.push(`Color ${processor.hex} read as ${processor.color}; confirm`);

      const stage = parseStage(values.stage);
      if (values.stage && !stage) issues.push(`Unrecognized status "${values.stage}"`);

      const key = norm(values.loan_number);
      const personKey = norm(values.borrower_name) + "|" + norm(values.property_address);
      let duplicateOf = (key && byNumber.get(key)) || (values.borrower_name && values.property_address ? byPerson.get(personKey) : undefined) || null;
      if (!duplicateOf) {
        const prior = rows.find((p) => (key && norm(p.values.loan_number) === key) ||
          (values.property_address && norm(p.values.borrower_name) + "|" + norm(p.values.property_address) === personKey));
        if (prior) duplicateOf = `${prior.sheet}!row ${prior.rowNumber}`;
      }
      if (duplicateOf) issues.push(`Likely duplicate of ${duplicateOf}`);

      rows.push({ sheet: ws.name, rowNumber: r, values, processor, stage, issues, duplicateOf });
    }
  }

  return {
    columnMap,
    unmappedHeaders: [...unmapped],
    rows,
    summary: {
      total: rows.length,
      assigned: rows.filter((r) => r.processor.status === "matched").length,
      needsColorReview: rows.filter((r) => r.processor.status === "review").length,
      withIssues: rows.filter((r) => r.issues.length).length,
      duplicates: rows.filter((r) => r.duplicateOf).length,
    },
  };
}
