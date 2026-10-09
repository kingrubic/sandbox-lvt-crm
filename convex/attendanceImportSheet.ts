import { cellTextPreserve } from "./studentRosterImportSheet.ts";

export const ATTENDANCE_IMPORT_MAX_BYTES = 4 * 1024 * 1024;
export const ATTENDANCE_IMPORT_MAX_ROWS = 3000;
export const ATTENDANCE_IMPORT_MAX_SHEETS = 10;
export const ATTENDANCE_IMPORT_MAX_HEADER_SCAN = 20;
export const ATTENDANCE_IMPORT_TTL_MS = 2 * 60 * 60 * 1000;

export const ATTENDANCE_COLUMN_KEYS = [
  "classCode",
  "studentName",
  "dateOfBirth",
  "sourceStatus",
  "observedAt",
] as const;

export type AttendanceColumnKey = (typeof ATTENDANCE_COLUMN_KEYS)[number];

/**
 * Template = file "Bảng thống kê điểm danh học sinh toàn trường" do hệ thống camera xuất ra.
 * Học sinh được nhận diện bằng Lớp + Họ tên + Ngày sinh (file không có mã học sinh).
 * Cột "Loại điểm danh" (nếu có) được bỏ qua.
 */
export const ATTENDANCE_TEMPLATE_HEADERS: Record<AttendanceColumnKey, string> = {
  classCode: "Lớp học",
  studentName: "Tên học sinh",
  dateOfBirth: "Ngày sinh",
  sourceStatus: "Trạng thái điểm danh",
  observedAt: "Thời gian điểm danh",
};

export const ATTENDANCE_REQUIRED_COLUMNS: AttendanceColumnKey[] = ["classCode", "studentName", "dateOfBirth", "sourceStatus"];

/** Normalized header keys accepted for each column (template names first, aliases after). */
export const ATTENDANCE_HEADER_ALIASES: Record<AttendanceColumnKey, string[]> = {
  classCode: ["lop_hoc", "lop", "ten_lop", "ma_lop", "class"],
  studentName: ["ten_hoc_sinh", "ho_va_ten", "ho_ten", "ho_ten_hoc_sinh", "ho_ten_hs", "hoten", "student_name"],
  dateOfBirth: ["ngay_sinh", "ngay_thang_nam_sinh", "date_of_birth", "dob"],
  sourceStatus: ["trang_thai_diem_danh", "trang_thai", "status"],
  observedAt: ["thoi_gian_diem_danh", "thoi_gian", "gio_diem_danh", "time"],
};

export type AttendanceRawRow = {
  rowNumber: number;
  rawClassCode: string;
  rawStudentName: string;
  rawDateOfBirth: string;
  rawObservedAt: string;
  rawStatus: string;
};

export function headerKey(value: unknown) {
  return cellTextPreserve(value)
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/đ/g, "d")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export function detectAttendanceHeader(matrix: unknown[][]): {
  rowIndex: number;
  columns: Partial<Record<AttendanceColumnKey, number>>;
  missing: AttendanceColumnKey[];
} | null {
  const limit = Math.min(matrix.length, ATTENDANCE_IMPORT_MAX_HEADER_SCAN);
  let best: { rowIndex: number; columns: Partial<Record<AttendanceColumnKey, number>>; score: number } | null = null;
  for (let r = 0; r < limit; r += 1) {
    const keys = (matrix[r] || []).map(headerKey);
    const columns: Partial<Record<AttendanceColumnKey, number>> = {};
    for (const key of ATTENDANCE_COLUMN_KEYS) {
      const index = keys.findIndex((header) => header && ATTENDANCE_HEADER_ALIASES[key].includes(header));
      if (index >= 0) columns[key] = index;
    }
    const score = Object.keys(columns).length;
    if (score >= 2 && (!best || score > best.score)) best = { rowIndex: r, columns, score };
  }
  if (!best) return null;
  return {
    rowIndex: best.rowIndex,
    columns: best.columns,
    missing: ATTENDANCE_REQUIRED_COLUMNS.filter((key) => best.columns[key] === undefined),
  };
}

export function rowsFromAttendanceMatrix(matrix: unknown[][]):
  | { ok: true; headerRowIndex: number; rows: AttendanceRawRow[]; truncated: boolean }
  | { ok: false; message: string; missing?: AttendanceColumnKey[] } {
  const header = detectAttendanceHeader(matrix);
  if (!header) return { ok: false, message: "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND" };
  if (header.missing.length) {
    return { ok: false, message: "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", missing: header.missing };
  }
  const cell = (line: unknown[], key: AttendanceColumnKey) => {
    const index = header.columns[key];
    return index === undefined ? "" : cellTextPreserve(line[index]);
  };
  const rows: AttendanceRawRow[] = [];
  let truncated = false;
  for (let r = header.rowIndex + 1; r < matrix.length; r += 1) {
    const line = matrix[r] || [];
    if (line.every((value) => cellTextPreserve(value) === "")) continue;
    if (rows.length >= ATTENDANCE_IMPORT_MAX_ROWS) {
      truncated = true;
      break;
    }
    rows.push({
      rowNumber: r + 1,
      rawClassCode: cell(line, "classCode"),
      rawStudentName: cell(line, "studentName"),
      rawDateOfBirth: cell(line, "dateOfBirth"),
      rawObservedAt: cell(line, "observedAt"),
      rawStatus: cell(line, "sourceStatus"),
    });
  }
  if (truncated) return { ok: false, message: "IMPORT_TOO_MANY_ROWS" };
  if (!rows.length) return { ok: false, message: "IMPORT_FILE_EMPTY" };
  return { ok: true, headerRowIndex: header.rowIndex, rows, truncated };
}
