import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import ExcelJS from "exceljs";
import { classifyColor } from "../import/colors";
import { previewWorkbook } from "../import/workbook";
import { ALL_STAGES, FINISHED_STAGES, MILESTONES, isOpen, loanProgress, stageAfterMilestone } from "../stages";

describe("processor color mapping", () => {
  it.each([
    ["FF7030A0", "Bobbie"], ["FF00B050", "Adel"], ["FFFFC000", "Katie"], ["FFFFFF00", "Moe"],
    ["#CCC0DA", "Bobbie"], ["C6EFCE", "Adel"], ["F8CBAD", "Katie"], ["FFF2CC", "Moe"],
  ])("%s -> %s", (hex, who) => {
    const m = classifyColor(hex);
    expect(m.status).toBe("matched");
    expect(m.status === "matched" && m.processor).toBe(who);
  });

  it.each(["FF0000", "0070C0", "FFFFFF", "D9D9D9", "000000", "FF5050", "C0FF00", ""])("flags %s for review", (hex) => {
    expect(classifyColor(hex).status).toBe("review");
  });
});

describe("stages", () => {
  it("finished vs open", () => {
    expect([...FINISHED_STAGES].sort()).toEqual(["cancelled", "denied", "funded"]);
    expect(isOpen("on_hold")).toBe(true);
    expect(isOpen("restructured")).toBe(true);
  });
  it("approval moves forward only", () => {
    expect(stageAfterMilestone("submitted", "approval")).toBe("approved");
    expect(stageAfterMilestone("clear_to_close", "approval")).toBe("clear_to_close");
    expect(stageAfterMilestone("on_hold", "approval")).toBe("on_hold");
    expect(() => stageAfterMilestone("funded", "approval")).toThrow();
  });
  it("progress", () => {
    expect(loanProgress(["submission", "esign"], [{ status: "received" }, { status: "outstanding" }]).percent).toBe(27);
  });
  it("matches the SQL seed", () => {
    const sql = readFileSync(new URL("../../../supabase/migrations/20261030000100_phase1_secure_loans.sql", import.meta.url), "utf8");
    for (const s of ALL_STAGES) {
      const finished = FINISHED_STAGES.has(s.key) ? "true" : "false";
      expect(sql).toMatch(new RegExp(`\\('${s.key}',\\s+'${s.label}',\\s+(\\d+|null),\\s+${finished}\\)`));
    }
    for (const m of MILESTONES) expect(sql).toMatch(new RegExp(`\\('${m.key}',\\s+'${m.label}',\\s+'${m.stage}'`));
  });
});

describe("workbook preview", () => {
  it("assigns by color, flags unknowns and duplicates", async () => {
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet("Pipeline");
    ws.addRow(["Borrower", "Loan #", "Loan Officer", "Property Address", "Status", "Closing Date"]);
    const rows: [string, string, string | null, string][] = [
      ["Jane Doe", "LN-1", "FF7030A0", "CTC"],
      ["John Roe", "LN-2", "FF00B050", "In UW"],
      ["Ann Poe", "LN-3", "FFFF0000", "Approved"],
      ["Bo Lee", "LN-4", null, "Mystery"],
      ["Jane Doe", "LN-1", "FFFFFF00", "CTC"],
    ];
    rows.forEach(([b, n, color, st], i) => {
      const r = ws.addRow([b, n, "Sam LO", `${i} Main St`, st, new Date("2026-11-15")]);
      if (color) r.getCell(3).fill = { type: "pattern", pattern: "solid", fgColor: { argb: color } };
    });
    const buf = await wb.xlsx.writeBuffer();
    const p = await previewWorkbook(buf as ArrayBuffer, [{ id: "existing-1", loan_number: "LN-2", borrower_name: "John Roe", property_address: "x" }]);

    expect(p.rows.map((r) => (r.processor.status === "matched" ? r.processor.processor : "REVIEW")))
      .toEqual(["Bobbie", "Adel", "REVIEW", "REVIEW", "Moe"]);
    expect(p.rows[0].stage).toBe("clear_to_close");
    expect(p.rows[1].duplicateOf).toBe("existing-1");
    expect(p.rows[4].duplicateOf).toBe("Pipeline!row 2");
    expect(p.rows[3].issues).toContain('Unrecognized status "Mystery"');
    expect(p.summary).toMatchObject({ total: 5, assigned: 3, needsColorReview: 2, duplicates: 2 });
  });
});
