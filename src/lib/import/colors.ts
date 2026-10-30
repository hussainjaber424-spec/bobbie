// Loan Officer row color -> processor. Purple -> Bobbie, Green -> Adel,
// Orange -> Katie, Yellow -> Moe. Anything else, or anything near a boundary,
// is flagged for management review instead of guessed.

export const COLOR_TO_PROCESSOR = {
  purple: "Bobbie",
  green: "Adel",
  orange: "Katie",
  yellow: "Moe",
} as const;

export type ProcessorColor = keyof typeof COLOR_TO_PROCESSOR;

export type ColorMatch =
  | { status: "matched"; color: ProcessorColor; processor: string; confidence: "exact" | "inferred"; hex: string }
  | { status: "review"; reason: string; hex: string | null };

// Common Excel standard / fill palette values, matched exactly.
const KNOWN: Record<string, ProcessorColor> = {
  "7030A0": "purple", "800080": "purple", "CCC0DA": "purple", "E4DFEC": "purple", "B1A0C7": "purple", "9966FF": "purple",
  "00B050": "green", "92D050": "green", "C6EFCE": "green", "E2EFDA": "green", "A9D08E": "green", "00FF00": "green", "70AD47": "green",
  "FFC000": "orange", "FFA500": "orange", "F4B084": "orange", "FCE4D6": "orange", "ED7D31": "orange", "F8CBAD": "orange", "FF9900": "orange",
  "FFFF00": "yellow", "FFEB9C": "yellow", "FFF2CC": "yellow", "FFE699": "yellow", "FFD966": "yellow",
};

// Hue bands with gaps between them; a hue in a gap is ambiguous.
const BANDS: [ProcessorColor, number, number][] = [
  ["orange", 18, 42],
  ["yellow", 48, 64],
  ["green", 80, 160],
  ["purple", 262, 318],
];

export function normalizeHex(input: string): string | null {
  const h = input.trim().replace(/^#/, "").toUpperCase();
  if (/^[0-9A-F]{8}$/.test(h)) return h.slice(2); // ARGB from Excel
  if (/^[0-9A-F]{6}$/.test(h)) return h;
  return null;
}

function hsl(hex: string) {
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  h = (h * 60 + 360) % 360;
  return { h, s, l };
}

export function classifyColor(input: string | null | undefined): ColorMatch {
  if (!input) return { status: "review", reason: "No highlight color", hex: null };
  const hex = normalizeHex(input);
  if (!hex) return { status: "review", reason: `Unreadable color "${input}"`, hex: null };

  const known = KNOWN[hex];
  if (known) return { status: "matched", color: known, processor: COLOR_TO_PROCESSOR[known], confidence: "exact", hex };

  const { h, s, l } = hsl(hex);
  if (s < 0.25 || l > 0.94 || l < 0.12) return { status: "review", reason: "Not a recognized processor color (gray/white/black)", hex };
  const band = BANDS.find(([, lo, hi]) => h >= lo && h <= hi);
  if (!band) return { status: "review", reason: `Ambiguous color (hue ${Math.round(h)}°)`, hex };
  return { status: "matched", color: band[0], processor: COLOR_TO_PROCESSOR[band[0]], confidence: "inferred", hex };
}

/** Excel theme color + tint -> hex. Theme order: lt1, dk1, lt2, dk2, accent1..6, hlink, folHlink. */
export function resolveThemeColor(themeHexes: string[], theme: number, tint = 0): string | null {
  const base = themeHexes[theme];
  if (!base) return null;
  const ch = [0, 2, 4].map((i) => parseInt(base.slice(i, i + 2), 16));
  const out = ch.map((c) => Math.round(tint < 0 ? c * (1 + tint) : c + (255 - c) * tint));
  return out.map((c) => Math.max(0, Math.min(255, c)).toString(16).padStart(2, "0")).join("").toUpperCase();
}

/** Pull the theme palette from a workbook's theme1.xml, in Excel's index order. */
export function parseThemePalette(themeXml: string | undefined): string[] {
  if (!themeXml) return [];
  const get = (tag: string) => {
    const m = themeXml.match(new RegExp(`<a:${tag}>([\\s\\S]*?)</a:${tag}>`));
    if (!m) return "";
    return m[1].match(/(?:srgbClr val|lastClr)="([0-9A-Fa-f]{6})"/)?.[1]?.toUpperCase() ?? "";
  };
  return ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"].map(get);
}
