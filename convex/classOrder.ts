/**
 * Natural ordering for homeroom classes: by grade, then the numeric class
 * number inside the grade, so 6-1, 6-2, …, 6-9, 6-10 (not 6-1, 6-10, 6-2).
 *
 * Mirrored for the web client in `src/homeroom/classOrder.js`; keep both in
 * sync (tests/class-order.test.mjs checks they agree).
 */

export type ClassOrderRow = {
  gradeLevel?: number | string | null;
  code?: string | null;
  name?: string | null;
  _id?: unknown;
  classId?: unknown;
};

const COLLATOR = new Intl.Collator("vi", { numeric: true, sensitivity: "base" });

function gradeOf(row: ClassOrderRow): number | null {
  const grade = Number(row?.gradeLevel);
  return Number.isFinite(grade) && String(row?.gradeLevel ?? "").trim() !== "" ? grade : null;
}

function escapeRegExp(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Class number within its grade, parsed from text such as "2627-6-10",
 * "Lớp 6-10", "6/10", "6A10" or "610" (grade 6). Returns null when the text
 * has no "<grade><separator?><number>" ending.
 */
export function parseClassNumber(text: unknown, gradeLevel: unknown): number | null {
  const value = String(text ?? "").trim();
  const grade = Number(gradeLevel);
  if (!value || !Number.isInteger(grade)) return null;
  const pattern = new RegExp(`(?:^|\\D)${escapeRegExp(String(grade))}\\s*(?:[-–/._]|[A-Za-z]{1,3})?\\s*(\\d{1,3})\\D*$`);
  const match = value.match(pattern);
  return match ? Number.parseInt(match[1], 10) : null;
}

export function classNumberOf(row: ClassOrderRow): number | null {
  const grade = gradeOf(row);
  if (grade === null) return null;
  return parseClassNumber(row?.code, grade) ?? parseClassNumber(row?.name, grade);
}

function nullsLast(a: number | null, b: number | null) {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;
  return a - b;
}

export function compareClasses(a: ClassOrderRow, b: ClassOrderRow): number {
  return (
    nullsLast(gradeOf(a), gradeOf(b))
    || nullsLast(classNumberOf(a), classNumberOf(b))
    || COLLATOR.compare(String(a?.code ?? ""), String(b?.code ?? ""))
    || COLLATOR.compare(String(a?.name ?? ""), String(b?.name ?? ""))
    || String(a?._id ?? a?.classId ?? "").localeCompare(String(b?._id ?? b?.classId ?? ""))
  );
}

/** Returns a new array sorted with {@link compareClasses}. */
export function sortClassesNatural<T extends ClassOrderRow>(rows: readonly T[]): T[] {
  return rows.slice().sort(compareClasses);
}
