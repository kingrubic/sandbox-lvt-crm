import {
  canReadClass,
  canReadClassOnAnyDateInRange,
  HOMEROOM_SCOPE_FORBIDDEN,
  type HomeroomActor,
  type HomeroomAssignment,
  type HomeroomClassScope,
} from "./homeroomPolicy.ts";
import { assertYmdRange } from "./homeroomTime.ts";
import type { EffectiveStatus } from "./studentAttendancePolicy.ts";

export type AttendanceDayRow = {
  classId: string;
  studentId: string;
  attendanceDate: string;
  effectiveStatus: EffectiveStatus | string;
  rawObservation?: string;
  enrollmentId?: string;
  studentCode?: string;
  fullName?: string;
};

export const UNKNOWN_STUDENT_CODE = "—";
export const UNKNOWN_STUDENT_NAME = "Học sinh không còn hiệu lực";

export type PublicStudentIdentity = {
  studentCode: string;
  fullName: string;
};

export type AttendanceStudentRecord = {
  _id: string;
  studentCode?: string;
  fullName?: string;
  status?: string;
};

export type ScopedClassRecord = {
  _id: string;
  name?: string;
  code?: string;
  schoolYearId?: string;
};

export type ScopedYearRecord = {
  _id: string;
  name?: string;
};

function usablePublicStudent(student?: AttendanceStudentRecord | null): boolean {
  if (!student) return false;
  if (student.status && student.status !== "active") return false;
  return true;
}

export function publicStudentIdentity(student?: AttendanceStudentRecord | null): PublicStudentIdentity {
  if (!usablePublicStudent(student)) {
    return { studentCode: UNKNOWN_STUDENT_CODE, fullName: UNKNOWN_STUDENT_NAME };
  }
  const studentCode = String(student?.studentCode || "").trim();
  const fullName = String(student?.fullName || "").trim();
  if (!studentCode && !fullName) {
    return { studentCode: UNKNOWN_STUDENT_CODE, fullName: UNKNOWN_STUDENT_NAME };
  }
  return {
    studentCode: studentCode || UNKNOWN_STUDENT_CODE,
    fullName: fullName || UNKNOWN_STUDENT_NAME,
  };
}

export function enrichAttendanceSummaryRows(
  days: AttendanceDayRow[],
  students: AttendanceStudentRecord[],
): Array<AttendanceDayRow & PublicStudentIdentity> {
  const byId = new Map(students.map((row) => [String(row._id), row]));
  return days.map((row) => ({
    ...row,
    ...publicStudentIdentity(byId.get(String(row.studentId))),
  }));
}

export function resolveScopedExportTitles(args: {
  classId?: string;
  schoolYearId?: string;
  scopedClassIds: string[];
  classes: ScopedClassRecord[];
  schoolYears: ScopedYearRecord[];
}): { className: string; schoolYearName: string } {
  const allowed = new Set(args.scopedClassIds.map(String));
  const scopedClasses = args.classes.filter((row) => allowed.has(String(row._id)));
  const requestedClass = args.classId
    ? scopedClasses.find((row) => String(row._id) === args.classId)
    : scopedClasses.length === 1
      ? scopedClasses[0]
      : undefined;
  const className = requestedClass ? String(requestedClass.name || requestedClass.code || "").trim() : "";

  const yearById = new Map(args.schoolYears.map((row) => [String(row._id), row]));
  const requestedYear = args.schoolYearId ? yearById.get(args.schoolYearId) : undefined;
  if (requestedYear?.name) {
    return { className, schoolYearName: String(requestedYear.name).trim() };
  }
  const yearNames = [
    ...new Set(
      scopedClasses
        .map((row) => yearById.get(String(row.schoolYearId || ""))?.name)
        .filter((name): name is string => Boolean(name && String(name).trim())),
    ),
  ];
  return {
    className,
    schoolYearName: yearNames.length === 1 ? String(yearNames[0]).trim() : "",
  };
}

const COUNTED_ABSENCE = new Set(["absent_excused", "absent_unexcused", "absent_pending"]);
const COUNTED_PRESENT = new Set(["present", "late"]);
const EXCLUDED_FROM_RATE = new Set(["exempt", "no_data"]);

export function summarizeAttendanceDays(
  days: AttendanceDayRow[],
  filters: { classIds?: string[]; from?: string; to?: string },
) {
  const classFilter = filters.classIds && filters.classIds.length ? new Set(filters.classIds) : null;
  const filtered = days.filter((row) => {
    if (classFilter && !classFilter.has(row.classId)) return false;
    if (filters.from && row.attendanceDate < filters.from) return false;
    if (filters.to && row.attendanceDate > filters.to) return false;
    return true;
  });

  const counts = {
    present: 0,
    late: 0,
    absent_excused: 0,
    absent_unexcused: 0,
    absent_pending: 0,
    no_data: 0,
    exempt: 0,
  };
  for (const row of filtered) {
    if (row.effectiveStatus in counts) {
      counts[row.effectiveStatus as keyof typeof counts] += 1;
    }
  }
  const rated = filtered.filter((row) => !EXCLUDED_FROM_RATE.has(row.effectiveStatus));
  const presentLike = rated.filter((row) => COUNTED_PRESENT.has(row.effectiveStatus)).length;
  const attendanceRate = rated.length ? presentLike / rated.length : 0;
  return {
    counts,
    totalRows: filtered.length,
    ratedRows: rated.length,
    absenceRows: filtered.filter((row) => COUNTED_ABSENCE.has(row.effectiveStatus)).length,
    attendanceRate,
    days: filtered,
  };
}

export type StudentAttendanceTotals = {
  studentId: string;
  studentCode: string;
  fullName: string;
  present: number;
  late: number;
  absent_excused: number;
  absent_unexcused: number;
  absent_pending: number;
  no_data: number;
  exempt: number;
  ratedRows: number;
  attendanceRate: number;
};

/** One row per student, sorted by most absences first, then roster label. */
export function summarizeByStudent(
  days: Array<AttendanceDayRow & Partial<PublicStudentIdentity>>,
): StudentAttendanceTotals[] {
  const byStudent = new Map<string, StudentAttendanceTotals>();
  for (const row of days) {
    const key = String(row.studentId);
    let entry = byStudent.get(key);
    if (!entry) {
      entry = {
        studentId: key,
        studentCode: row.studentCode || UNKNOWN_STUDENT_CODE,
        fullName: row.fullName || UNKNOWN_STUDENT_NAME,
        present: 0,
        late: 0,
        absent_excused: 0,
        absent_unexcused: 0,
        absent_pending: 0,
        no_data: 0,
        exempt: 0,
        ratedRows: 0,
        attendanceRate: 0,
      };
      byStudent.set(key, entry);
    }
    const status = row.effectiveStatus as keyof StudentAttendanceTotals;
    if (status in entry && typeof entry[status] === "number" && status !== "ratedRows" && status !== "attendanceRate") {
      (entry[status] as number) += 1;
    }
  }
  const rows = [...byStudent.values()].map((entry) => {
    const rated = entry.present + entry.late + entry.absent_excused + entry.absent_unexcused + entry.absent_pending;
    return {
      ...entry,
      ratedRows: rated,
      attendanceRate: rated ? (entry.present + entry.late) / rated : 0,
    };
  });
  const absences = (row: StudentAttendanceTotals) => row.absent_excused + row.absent_unexcused + row.absent_pending;
  return rows.sort(
    (a, b) =>
      absences(b) - absences(a)
      || b.late - a.late
      || a.fullName.localeCompare(b.fullName, "vi")
      || a.studentCode.localeCompare(b.studentCode, "vi"),
  );
}

export function buildAttendanceExportPayload(args: {
  summary: ReturnType<typeof summarizeAttendanceDays>;
  schoolName?: string;
  className?: string;
  schoolYearName?: string;
  from: string;
  to: string;
  generatedAt: number;
  generatedByUserId: string;
  generatedByName?: string;
  studentTotals?: StudentAttendanceTotals[];
}) {
  return {
    title: "Báo cáo điểm danh lớp chủ nhiệm",
    schoolName: args.schoolName || "THCS Lê Văn Tám",
    className: args.className || "",
    schoolYearName: args.schoolYearName || "",
    from: args.from,
    to: args.to,
    generatedAt: args.generatedAt,
    generatedByUserId: args.generatedByUserId,
    generatedByName: args.generatedByName || "",
    totals: args.summary.counts,
    attendanceRate: args.summary.attendanceRate,
    ratedRows: args.summary.ratedRows,
    studentTotals: (args.studentTotals || []).map((row) => ({
      studentCode: row.studentCode,
      fullName: row.fullName,
      present: row.present,
      late: row.late,
      absent_excused: row.absent_excused,
      absent_unexcused: row.absent_unexcused,
      absent_pending: row.absent_pending,
      attendanceRate: row.attendanceRate,
    })),
    rows: args.summary.days.map((row) => ({
      classId: row.classId,
      studentId: row.studentId,
      studentCode: row.studentCode || "",
      fullName: row.fullName || "",
      attendanceDate: row.attendanceDate,
      effectiveStatus: row.effectiveStatus,
      rawObservation: row.rawObservation || "",
    })),
  };
}

export function authorizeAttendanceSummaryRows(
  args: {
    actor: HomeroomActor;
    assignments: HomeroomAssignment[];
    days: AttendanceDayRow[];
    classId?: string;
    from: string;
    to: string;
    schoolYearId?: string;
  },
): AttendanceDayRow[] {
  const range = assertYmdRange(args.from, args.to);
  if (
    !canReadClassOnAnyDateInRange(args.actor, args.assignments, args.classId, {
      from: range.from,
      to: range.to,
      schoolYearId: args.schoolYearId,
    })
  ) {
    throw new Error(HOMEROOM_SCOPE_FORBIDDEN);
  }
  return args.days.filter((row) => {
    if (args.classId && row.classId !== args.classId) return false;
    if (row.attendanceDate < range.from || row.attendanceDate > range.to) return false;
    return canReadClass(args.actor, args.assignments, row.classId, row.attendanceDate);
  });
}

export function assertExportWithinScope(
  requestedClassIds: string[] | undefined,
  scope: HomeroomClassScope,
) {
  if (scope.kind === "all") return requestedClassIds || [];
  if (scope.kind === "none") {
    if (requestedClassIds?.length) throw new Error("HOMEROOM_SCOPE_FORBIDDEN");
    return [];
  }
  const allowed = new Set(scope.classIds);
  const requested = requestedClassIds?.length ? requestedClassIds : scope.classIds;
  if (requested.some((id) => !allowed.has(id))) throw new Error("HOMEROOM_SCOPE_FORBIDDEN");
  return requested;
}
