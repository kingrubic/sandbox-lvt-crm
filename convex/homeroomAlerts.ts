import { vietnamDateFromUtcMs, vietnamWallTimeToUtcMs } from "./homeroomTime.ts";

export type SchoolCalendarDay = {
  date: string;
  kind: string;
};

export type AttendanceAlertRow = {
  classId: string;
  studentId: string;
  attendanceDate: string;
  effectiveStatus?: string;
  rawObservation?: string;
};

export function evaluateMissingUploadAlert(args: {
  date: string;
  nowMs: number;
  cutoffTime: string;
  calendarDay: SchoolCalendarDay | null;
  publishedImportId?: string | null;
}) {
  const evaluatedDate = args.date;
  const cutoffAt = vietnamWallTimeToUtcMs(args.date, args.cutoffTime);
  const afterCutoff = args.nowMs >= cutoffAt;
  const today = vietnamDateFromUtcMs(args.nowMs);
  const dateIsTodayOrPast = evaluatedDate <= today;

  if (args.publishedImportId) {
    return {
      shouldAlert: false,
      calendarStatus: args.calendarDay?.kind || "unconfigured",
      resolvedByPublication: true,
      evaluatedDate,
      cutoffTime: args.cutoffTime,
      cutoffAt,
    };
  }

  if (!args.calendarDay) {
    const schoolDay = isDefaultSchoolDay(evaluatedDate);
    return {
      shouldAlert: Boolean(schoolDay && afterCutoff && dateIsTodayOrPast),
      calendarStatus: schoolDay ? DEFAULT_SCHOOL_DAY : DEFAULT_WEEKEND,
      resolvedByPublication: false,
      evaluatedDate,
      cutoffTime: args.cutoffTime,
      cutoffAt,
    };
  }

  const working = isSchoolDayKind(args.calendarDay.kind);
  return {
    shouldAlert: Boolean(working && afterCutoff && dateIsTodayOrPast),
    calendarStatus: args.calendarDay.kind,
    resolvedByPublication: false,
    evaluatedDate,
    cutoffTime: args.cutoffTime,
    cutoffAt,
  };
}

export const DEFAULT_SCHOOL_DAY = "default_school_day";
export const DEFAULT_WEEKEND = "default_weekend";
export const CALENDAR_KINDS = ["holiday", "extra_teaching", "working"] as const;

/** 0 = Sunday … 6 = Saturday, computed on the calendar date (no timezone drift). */
export function weekdayOfYmd(date: string): number {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day)).getUTCDay();
}

/** Default rule agreed with the school: Thứ 2 – Thứ 6 are school days. */
export function isDefaultSchoolDay(date: string): boolean {
  const weekday = weekdayOfYmd(date);
  return weekday >= 1 && weekday <= 5;
}

export function isSchoolDayKind(kind: string): boolean {
  return kind === "working" || kind === "extra_teaching";
}

export function resolveSchoolDay(
  date: string,
  calendarDay: SchoolCalendarDay | null | undefined,
  year?: { startDate: string; endDate: string } | null,
): { isSchoolDay: boolean; kind: string; note?: string; outsideYear: boolean } {
  const outsideYear = Boolean(year && (date < year.startDate || date > year.endDate));
  if (calendarDay) {
    return {
      isSchoolDay: !outsideYear && isSchoolDayKind(calendarDay.kind),
      kind: calendarDay.kind,
      note: (calendarDay as { note?: string }).note,
      outsideYear,
    };
  }
  const schoolDay = isDefaultSchoolDay(date);
  return {
    isSchoolDay: !outsideYear && schoolDay,
    kind: schoolDay ? DEFAULT_SCHOOL_DAY : DEFAULT_WEEKEND,
    outsideYear,
  };
}

export function evaluateScopedMissingUploadAlerts(args: {
  date: string;
  nowMs: number;
  cutoffTime: string;
  calendarDay: SchoolCalendarDay | null;
  visibleClassIds: string[];
  publishedClassIds: string[];
}) {
  const visibleClassIds = [...new Set(args.visibleClassIds.filter(Boolean))];
  const published = new Set(args.publishedClassIds.filter(Boolean));
  if (!visibleClassIds.length) {
    const empty = evaluateMissingUploadAlert({
      date: args.date,
      nowMs: args.nowMs,
      cutoffTime: args.cutoffTime,
      calendarDay: args.calendarDay,
      publishedImportId: null,
    });
    return {
      ...empty,
      shouldAlert: false,
      resolvedByPublication: false,
      missingClassIds: [] as string[],
      scopeEmpty: true,
    };
  }
  const missingClassIds = visibleClassIds.filter((classId) => !published.has(classId));
  const base = evaluateMissingUploadAlert({
    date: args.date,
    nowMs: args.nowMs,
    cutoffTime: args.cutoffTime,
    calendarDay: args.calendarDay,
    publishedImportId: missingClassIds.length ? null : "all-visible-published",
  });
  return {
    ...base,
    shouldAlert: Boolean(base.shouldAlert && missingClassIds.length),
    resolvedByPublication: missingClassIds.length === 0,
    missingClassIds,
    scopeEmpty: false,
  };
}

export function evaluateUnresolvedAbsenceAlerts(
  days: AttendanceAlertRow[],
  args: { classIds?: string[] },
) {
  const allowed = args.classIds && args.classIds.length ? new Set(args.classIds) : null;
  return days.filter((row) => {
    if (allowed && !allowed.has(row.classId)) return false;
    return row.effectiveStatus === "absent_pending";
  });
}

export function evaluateRepeatedAbsenceAlert(
  days: AttendanceAlertRow[],
  args: { studentId: string; threshold?: number },
) {
  const threshold = args.threshold ?? 3;
  const matches = days.filter(
    (row) =>
      row.studentId === args.studentId &&
      (row.rawObservation === "absent" ||
        row.effectiveStatus === "absent_pending" ||
        row.effectiveStatus === "absent_excused" ||
        row.effectiveStatus === "absent_unexcused"),
  );
  return { shouldAlert: matches.length >= threshold, count: matches.length, threshold };
}

export function evaluateRepeatedLatenessAlert(
  days: AttendanceAlertRow[],
  args: { studentId: string; threshold?: number },
) {
  const threshold = args.threshold ?? 3;
  const matches = days.filter(
    (row) => row.studentId === args.studentId && (row.rawObservation === "late" || row.effectiveStatus === "late"),
  );
  return { shouldAlert: matches.length >= threshold, count: matches.length, threshold };
}
