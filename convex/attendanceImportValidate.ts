import { parseFlexibleSchoolDate, vietnamWallTimeToUtcMs } from "./homeroomTime.ts";

export const PRESENCE_POLICY_POSITIVE = "positive_presence";
export const PRESENCE_POLICY_FULL_ROSTER = "full_roster";
export const REPLACE_MODE_SUPPLEMENT = "supplement";
export const REPLACE_MODE_REPLACE = "replace_camera_observations";
export const REPLACE_MODE_CANCEL = "cancel";

export type CameraStudent = {
  studentId: string;
  studentCode: string;
  fullName: string;
  dateOfBirth?: string;
  classId: string;
  classCode: string;
  enrollmentId: string;
};

export type AttendanceImportIssue = {
  rowNumber: number;
  field: string;
  column: string;
  rejectedValue: string | null;
  code: string;
  message: string;
  severity: "error" | "warning";
};

export function decidePublishedDateAction(args: {
  existingPublished: { importId: string; checksum: string; attendanceDate: string } | null;
  nextChecksum: string;
  attendanceDate: string;
  requestedMode?: string;
}) {
  if (!args.existingPublished) return { action: "publish" as const };
  if (
    args.existingPublished.checksum === args.nextChecksum &&
    args.existingPublished.attendanceDate === args.attendanceDate
  ) {
    return { action: "idempotent" as const, importId: args.existingPublished.importId };
  }
  const mode = args.requestedMode;
  if (mode === REPLACE_MODE_SUPPLEMENT) return { action: "supplement" as const };
  if (mode === REPLACE_MODE_REPLACE) return { action: "replace" as const };
  if (mode === REPLACE_MODE_CANCEL) return { action: "cancel" as const };
  return { action: "require_mode" as const, code: "ATTENDANCE_REPLACE_MODE_REQUIRED" };
}

/* ------------------------------------------------------------------ */
/* Whole-school file (one file per day, split by Lớp học)              */
/* Học sinh được nhận diện bằng Lớp + Họ tên + Ngày sinh.              */
/* ------------------------------------------------------------------ */

export type SchoolCameraClass = { classId: string; code: string; name: string };

export type SchoolCameraRow = {
  rowNumber: number;
  rawClassCode?: string;
  rawStudentName?: string;
  rawDateOfBirth?: string;
  rawObservedAt?: string;
  rawStatus?: string;
};

export type SchoolClassPreview = {
  classId: string;
  code: string;
  name: string;
  rowCount: number;
  matchedCount: number;
  present: number;
  late: number;
  absent: number;
  rosterCount: number;
  missingCount: number;
  errorCount: number;
  warningCount: number;
  publishable: boolean;
};

function foldText(value: string) {
  return value
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/đ/g, "d")
    .replace(/\s+/g, " ");
}

/**
 * "7/1", "Lớp 7/1", " 7 - 1 " → "7-1". Mã lớp trên phần mềm không cho phép "/", nên "/" "." "_" được coi như "-".
 * Áp dụng cho cả mã lớp và tên lớp trên phần mềm.
 */
export function classMatchKey(value: string) {
  return foldText(value).replace(/^lop\s*/, "").replace(/\s+/g, "").replace(/[/._]/g, "-");
}

/** Họ tên không phân biệt dấu/hoa thường/khoảng trắng (Thuỳ = Thùy) + ngày sinh YYYY-MM-DD. */
export function studentMatchKey(fullName: string, dateOfBirth: string) {
  return `${foldText(fullName)}|${dateOfBirth}`;
}

const SCHOOL_STATUS_ALIASES: Record<string, "present" | "late" | "absent"> = {
  "dung gio": "present",
  // File camera đời cũ ghi "Đã điểm danh" — vẫn nhận để nhập lại dữ liệu cũ.
  "da diem danh": "present",
  "di tre": "late",
  "chua diem danh": "absent",
};

/** Trạng thái file camera: Đúng giờ / Đi trễ / Chưa điểm danh (không dấu cũng được). Null khi trống hoặc lạ. */
export function parseSchoolCameraStatus(value: string | undefined): "present" | "late" | "absent" | null {
  return SCHOOL_STATUS_ALIASES[foldText(value || "")] || null;
}

/** "07:05", "7:05 AM", "01/09/2026 07:05" → epoch ms của ngày điểm danh. "--:--" / trống → undefined. */
function observedAtMs(raw: string | undefined, attendanceDate: string) {
  const text = String(raw || "");
  const match = text.match(/(\d{1,2}):(\d{2})/);
  if (!match) return undefined;
  let hour = Number(match[1]);
  if (/\bpm\b/i.test(text) && hour < 12) hour += 12;
  if (/\bam\b/i.test(text) && hour === 12) hour = 0;
  if (hour > 23 || Number(match[2]) > 59) return undefined;
  return vietnamWallTimeToUtcMs(attendanceDate, `${String(hour).padStart(2, "0")}:${match[2]}`);
}

function observedDate(raw: string | undefined) {
  const match = String(raw || "").match(/\d{4}-\d{2}-\d{2}|\d{1,2}[/.-]\d{1,2}[/.-]\d{4}/);
  return match ? parseFlexibleSchoolDate(match[0]) : null;
}

function dmy(ymd: string) {
  return ymd.split("-").reverse().join("/");
}

export function reconcileSchoolAttendanceRows(
  rows: SchoolCameraRow[],
  context: {
    attendanceDate: string;
    classes: SchoolCameraClass[];
    students: CameraStudent[];
  },
) {
  const classByKey = new Map<string, SchoolCameraClass>();
  for (const klass of context.classes) classByKey.set(classMatchKey(klass.name), klass);
  for (const klass of context.classes) classByKey.set(classMatchKey(klass.code), klass);
  const studentsByKey = new Map<string, CameraStudent[]>();
  for (const student of context.students) {
    if (!student.dateOfBirth) continue;
    const key = studentMatchKey(student.fullName, student.dateOfBirth);
    studentsByKey.set(key, [...(studentsByKey.get(key) || []), student]);
  }

  const issues: AttendanceImportIssue[] = [];
  const seenStudentIds = new Set<string>();
  const previews = new Map<string, SchoolClassPreview>();
  const matchedByClass = new Map<string, Set<string>>();
  const normalizedRows: Array<SchoolCameraRow & {
    targetClassId?: string;
    matchedStudentId?: string;
    resolution: string;
    rawObservation: "present" | "late" | "absent" | "unknown";
    normalizedObservedAt?: number;
  }> = [];

  for (const row of rows) {
    const rowIssues: AttendanceImportIssue[] = [];
    const fail = (field: string, value: string | undefined | null, code: string, message: string) => {
      rowIssues.push({ rowNumber: row.rowNumber, field, column: field, rejectedValue: value || null, code, message, severity: "error" });
    };

    const rawClass = (row.rawClassCode || "").trim();
    const klass = rawClass ? classByKey.get(classMatchKey(rawClass)) : undefined;
    if (!rawClass) fail("classCode", null, "CAMERA_CLASS_MISSING", "Thiếu lớp học.");
    else if (!klass) fail("classCode", rawClass, "CAMERA_CLASS_UNKNOWN", "Lớp không có trong năm học (hoặc lớp đã lưu trữ).");

    const status = parseSchoolCameraStatus(row.rawStatus);
    if (!(row.rawStatus || "").trim()) {
      fail("sourceStatus", null, "CAMERA_STATUS_MISSING", "Thiếu trạng thái (Đúng giờ / Đi trễ / Chưa điểm danh).");
    } else if (!status) {
      fail("sourceStatus", row.rawStatus, "CAMERA_STATUS_INVALID", "Trạng thái chỉ nhận: Đúng giờ, Đi trễ, Chưa điểm danh.");
    }

    const name = (row.rawStudentName || "").trim();
    if (!name) fail("studentName", null, "CAMERA_NAME_MISSING", "Thiếu tên học sinh.");
    const dob = parseFlexibleSchoolDate(row.rawDateOfBirth);
    if (!(row.rawDateOfBirth || "").trim()) fail("dateOfBirth", null, "CAMERA_DOB_MISSING", "Thiếu ngày sinh.");
    else if (!dob) fail("dateOfBirth", row.rawDateOfBirth, "CAMERA_DOB_INVALID", "Ngày sinh không hợp lệ (dd/mm/yyyy).");

    let matched: CameraStudent | undefined;
    if (klass && name && dob) {
      const candidates = studentsByKey.get(studentMatchKey(name, dob)) || [];
      const inClass = candidates.filter((student) => student.classId === klass.classId);
      if (inClass.length === 1) {
        matched = inClass[0];
      } else if (inClass.length > 1) {
        fail("studentName", name, "CAMERA_STUDENT_AMBIGUOUS", "Nhiều học sinh trùng họ tên và ngày sinh trong lớp. Không tự động khớp.");
      } else if (candidates.length) {
        fail(
          "classCode",
          rawClass,
          "CAMERA_WRONG_CLASS",
          `Học sinh đang học lớp ${candidates.map((student) => student.classCode).join(", ")} trên phần mềm. Không tự động chuyển lớp khi nhập điểm danh.`,
        );
      } else {
        const sameName = context.students.filter(
          (student) => student.classId === klass.classId && foldText(student.fullName) === foldText(name),
        );
        if (sameName.length) {
          const onFile = sameName.map((student) => (student.dateOfBirth ? dmy(student.dateOfBirth) : "chưa có ngày sinh")).join(", ");
          fail("dateOfBirth", row.rawDateOfBirth, "CAMERA_DOB_MISMATCH", `Ngày sinh không khớp hồ sơ học sinh (trên phần mềm: ${onFile}).`);
        } else {
          fail("studentName", name, "CAMERA_UNMATCHED", "Không tìm thấy học sinh có họ tên này trong lớp.");
        }
      }
    }
    if (matched) {
      if (seenStudentIds.has(matched.studentId)) {
        fail("studentName", name, "CAMERA_DUPLICATE_ROW", "Trùng học sinh trong cùng file.");
      }
      seenStudentIds.add(matched.studentId);
    }

    const obsDate = observedDate(row.rawObservedAt);
    if (obsDate && obsDate !== context.attendanceDate) {
      fail("observedAt", row.rawObservedAt, "CAMERA_DATE_MISMATCH", "Thời gian điểm danh không thuộc ngày điểm danh đã chọn.");
    }

    const resolution = matched && !rowIssues.length ? "matched" : "invalid";
    if (klass) {
      const preview = previews.get(klass.classId) || {
        classId: klass.classId,
        code: klass.code,
        name: klass.name,
        rowCount: 0,
        matchedCount: 0,
        present: 0,
        late: 0,
        absent: 0,
        rosterCount: context.students.filter((student) => student.classId === klass.classId).length,
        missingCount: 0,
        errorCount: 0,
        warningCount: 0,
        publishable: false,
      };
      preview.rowCount += 1;
      preview.errorCount += rowIssues.length;
      if (resolution === "matched" && matched) {
        preview.matchedCount += 1;
        if (status) preview[status] += 1;
        const set = matchedByClass.get(klass.classId) || new Set<string>();
        set.add(matched.studentId);
        matchedByClass.set(klass.classId, set);
      }
      previews.set(klass.classId, preview);
    }

    issues.push(...rowIssues);
    normalizedRows.push({
      ...row,
      targetClassId: klass?.classId,
      matchedStudentId: matched?.studentId,
      resolution,
      rawObservation: status || "unknown",
      normalizedObservedAt: status === "absent" ? undefined : observedAtMs(row.rawObservedAt, context.attendanceDate),
    });
  }

  const classPreviews = context.classes.flatMap((klass) => {
    const preview = previews.get(klass.classId);
    if (!preview) return [];
    preview.missingCount = preview.rosterCount - (matchedByClass.get(klass.classId)?.size || 0);
    preview.publishable = preview.errorCount === 0 && preview.matchedCount > 0;
    return [preview];
  });

  const blockers = issues.filter((item) => item.severity === "error");
  return {
    ok: blockers.length === 0 && classPreviews.length > 0,
    totalRows: rows.length,
    issues,
    blockers,
    classes: classPreviews,
    publishableClassIds: classPreviews.filter((row) => row.publishable).map((row) => row.classId),
    rows: normalizedRows,
    matchedCount: classPreviews.reduce((sum, row) => sum + row.matchedCount, 0),
    warningCount: issues.filter((item) => item.severity === "warning").length,
    errorCount: blockers.length,
  };
}
