import { v } from "convex/values";
import { anyApi } from "convex/server";
import { action, internalMutation, internalQuery, mutation, query, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import {
  parseSchoolCameraStatus,
  PRESENCE_POLICY_POSITIVE,
  reconcileSchoolAttendanceRows,
  REPLACE_MODE_CANCEL,
  REPLACE_MODE_REPLACE,
  REPLACE_MODE_SUPPLEMENT,
} from "./attendanceImportValidate";
import { ATTENDANCE_IMPORT_MAX_BYTES, ATTENDANCE_IMPORT_TTL_MS } from "./attendanceImportSheet";
import {
  applyPublicationPolicy,
  attendanceImportPublishResult,
  planAttendanceImportWrites,
} from "./studentAttendancePolicy";
import { assertAttendanceImporter, homeroomActorOrThrow, writeAudit } from "./homeroomContext";
import { enrollmentsCoveringDate } from "./homeroomCatalog";
import { assertYmd, vietnamDateFromUtcMs } from "./homeroomTime";
import type { DbCtx } from "./lib";
import { assertImportUploadUsable } from "./userImportPolicy";
import { assertStoredImportMetadata } from "./studentRosterImportValidate";
import { resolveSchoolDay } from "./homeroomAlerts";
import {
  calendarDayFor,
  classesForYear,
  daysForClassOnDate,
  daysForYearOnDate,
  enrollmentsForClassOnDate,
  enrollmentsForYear,
  importRowsFor,
  studentsByIds,
  usersByIds,
} from "./homeroomData";
import { compareClasses } from "./classOrder";

const internal = anyApi;
const ISSUE_RETURN_LIMIT = 400;
export const SCHOOL_SOURCE_KIND = "camera_school_excel";

type SchoolRoster = {
  classes: Array<{ classId: string; code: string; name: string }>;
  students: Array<{
    studentId: string;
    studentCode: string;
    fullName: string;
    dateOfBirth?: string;
    classId: string;
    classCode: string;
    enrollmentId: string;
  }>;
  publishedClassIds: string[];
  schoolDay: ReturnType<typeof resolveSchoolDay>;
};

export const generateUploadUrl = mutation({
  args: { schoolYearId: v.string(), attendanceDate: v.string() },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    assertYmd(args.attendanceDate);
    await assertAttendanceImporter(ctx, actor, args.schoolYearId);
    return await ctx.storage.generateUploadUrl();
  },
});

export const registerUpload = mutation({
  args: {
    storageId: v.id("_storage"),
    fileName: v.string(),
    fileSize: v.number(),
    schoolYearId: v.string(),
    attendanceDate: v.string(),
  },
  handler: async (ctx, args) => {
    const { user, actor } = await homeroomActorOrThrow(ctx);
    const attendanceDate = assertYmd(args.attendanceDate);
    const year = await assertAttendanceImporter(ctx, actor, args.schoolYearId);
    if (attendanceDate < year.startDate || attendanceDate > year.endDate) throw new Error("ATTENDANCE_DATE_OUTSIDE_YEAR");
    if (attendanceDate > vietnamDateFromUtcMs(Date.now())) throw new Error("ATTENDANCE_DATE_IN_FUTURE");
    const stored = await ctx.db.system.get("_storage", args.storageId);
    assertStoredImportMetadata(stored, { fileSize: args.fileSize, maxBytes: ATTENDANCE_IMPORT_MAX_BYTES });
    const fileName = args.fileName.trim();
    if (!fileName.toLowerCase().endsWith(".xlsx")) throw new Error("INVALID_IMPORT_FILE");
    const now = Date.now();
    const uploadId = await ctx.db.insert("attendanceImportUploads", {
      schoolYearId: args.schoolYearId,
      attendanceDate,
      sourceKind: SCHOOL_SOURCE_KIND,
      fileName,
      fileSize: args.fileSize,
      checksum: "pending",
      storageId: args.storageId,
      uploadedBy: String(user._id),
      columnMapping: {},
      presencePolicy: PRESENCE_POLICY_POSITIVE,
      status: "uploaded",
      rowCount: 0,
      matchedCount: 0,
      warningCount: 0,
      errorCount: 0,
      createdAt: now,
      updatedAt: now,
      expiresAt: now + ATTENDANCE_IMPORT_TTL_MS,
    });
    await writeAudit(ctx, {
      actorUserId: String(user._id),
      action: "attendanceImport.upload",
      details: JSON.stringify({ uploadId, attendanceDate }),
    });
    return { uploadId };
  },
});

/** Đọc file, đối soát toàn trường theo Lớp + Họ tên + Ngày sinh và lưu bản xem trước. Không ghi điểm danh. */
export const validate = action({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await ctx.runQuery(internal.attendanceImport.getUploadInternal, { uploadId: args.uploadId });
    if (!upload) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
    const parsed = await ctx.runAction(internal.attendanceImportParse.parseStorageXlsx, {
      storageId: upload.storageId,
    });
    if (!parsed.ok) {
      const missing = (parsed.missing || []).join(",");
      throw new Error(missing ? `${parsed.message}:${missing}` : parsed.message);
    }
    const roster: SchoolRoster = await ctx.runQuery(internal.attendanceImport.loadSchoolRosterInternal, {
      schoolYearId: upload.schoolYearId,
      attendanceDate: upload.attendanceDate,
    });
    const result = reconcileSchoolAttendanceRows(parsed.rows, {
      attendanceDate: upload.attendanceDate,
      classes: roster.classes,
      students: roster.students,
    });
    await ctx.runMutation(internal.attendanceImport.storePreviewInternal, {
      uploadId: args.uploadId,
      checksum: parsed.checksum,
      rowCount: result.totalRows,
      matchedCount: result.matchedCount,
      warningCount: result.warningCount,
      errorCount: result.errorCount,
      status: result.publishableClassIds.length ? "validated" : "rejected",
      rows: result.rows.map((row) => ({
        rowNumber: row.rowNumber,
        rawStudentName: row.rawStudentName || undefined,
        rawDateOfBirth: row.rawDateOfBirth || undefined,
        rawClassCode: row.rawClassCode || undefined,
        rawObservedAt: row.rawObservedAt || undefined,
        rawStatus: row.rawStatus || undefined,
        matchedStudentId: row.matchedStudentId,
        matchedClassId: row.targetClassId,
        resolution: row.resolution,
        messages: result.issues.filter((item) => item.rowNumber === row.rowNumber).map((item) => item.message),
        normalizedObservedAt: row.normalizedObservedAt,
      })),
    });
    const published = new Set(roster.publishedClassIds);
    return {
      uploadId: args.uploadId,
      attendanceDate: upload.attendanceDate,
      fileName: upload.fileName,
      sheetName: parsed.sheetName,
      ok: result.ok,
      totalRows: result.totalRows,
      matchedCount: result.matchedCount,
      errorCount: result.errorCount,
      warningCount: result.warningCount,
      issues: result.issues.slice(0, ISSUE_RETURN_LIMIT),
      issuesTruncated: result.issues.length > ISSUE_RETURN_LIMIT,
      classes: result.classes.map((row) => ({ ...row, alreadyPublished: published.has(row.classId) })),
      classesWithoutRows: roster.classes
        .filter((row) => !result.classes.some((item) => item.classId === row.classId))
        .map((row) => ({ classId: row.classId, code: row.code, name: row.name, alreadyPublished: published.has(row.classId) })),
      schoolDay: roster.schoolDay,
    };
  },
});

export const publish = mutation({
  args: { uploadId: v.string(), replaceMode: v.optional(v.string()) },
  handler: async (ctx, args) => {
    return await publishStoredImport(ctx, args);
  },
});

/** Các file đã nhập cho một ngày (để biết ngày đó đã công bố chưa, bởi ai). */
export const uploadsForDate = query({
  args: { schoolYearId: v.string(), attendanceDate: v.string() },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    await assertAttendanceImporter(ctx, actor, args.schoolYearId);
    const date = assertYmd(args.attendanceDate);
    const uploads = (
      await ctx.db
        .query("attendanceImportUploads")
        .withIndex("by_date", (q) => q.eq("attendanceDate", date))
        .collect()
    ).filter((row) => row.schoolYearId === args.schoolYearId && row.status === "published");
    const users = await usersByIds(ctx, uploads.map((row) => row.uploadedBy));
    const days = await daysForYearOnDate(ctx, args.schoolYearId, date);
    return {
      publishedClassCount: new Set(days.map((row) => row.classId)).size,
      uploads: uploads
        .sort((a, b) => (b.publishedAt || 0) - (a.publishedAt || 0))
        .map((row) => ({
          _id: String(row._id),
          fileName: row.fileName,
          publishedAt: row.publishedAt,
          uploadedByName: users.get(row.uploadedBy)?.name || "",
          rowCount: row.rowCount,
          matchedCount: row.matchedCount,
        })),
    };
  },
});

async function assertAttendanceUploadActor(
  ctx: DbCtx,
  upload: {
    uploadedBy: string;
    status: string;
    expiresAt?: number;
    schoolYearId: string;
  },
) {
  const { actor } = await homeroomActorOrThrow(ctx);
  assertImportUploadUsable(
    {
      uploadedBy: upload.uploadedBy,
      status: upload.status,
      expiresAt: upload.expiresAt ?? 0,
    },
    { actorId: actor.userId },
  );
  await assertAttendanceImporter(ctx, actor, upload.schoolYearId);
  return { actor };
}

export const getUploadInternal = internalQuery({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const id = ctx.db.normalizeId("attendanceImportUploads", args.uploadId);
    const upload = id ? await ctx.db.get(id) : null;
    if (!upload) return null;
    if (upload.sourceKind !== SCHOOL_SOURCE_KIND) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
    await assertAttendanceUploadActor(ctx, upload);
    return upload;
  },
});

/** Active classes of the year + every student enrolled on the date (for code/class matching). */
export const loadSchoolRosterInternal = internalQuery({
  args: { schoolYearId: v.string(), attendanceDate: v.string() },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    const year = await assertAttendanceImporter(ctx, actor, args.schoolYearId);
    const date = assertYmd(args.attendanceDate);
    const classes = (await classesForYear(ctx, args.schoolYearId)).filter((row) => row.status === "active");
    const classById = new Map(classes.map((row) => [String(row._id), row]));
    const enrollments = (await enrollmentsForYear(ctx, args.schoolYearId)).filter((row) => classById.has(row.classId));
    const covering = classes.flatMap((klass) => enrollmentsCoveringDate(enrollments, { classId: String(klass._id), date }));
    const students = await studentsByIds(ctx, covering.map((row) => row.studentId));
    const days = await daysForYearOnDate(ctx, args.schoolYearId, date);
    const calendarDay = await calendarDayFor(ctx, args.schoolYearId, date);
    return {
      classes: classes
        .sort(compareClasses)
        .map((row) => ({ classId: String(row._id), code: row.code, name: row.name })),
      students: covering.flatMap((enrollment) => {
        const student = students.get(enrollment.studentId);
        const klass = classById.get(enrollment.classId);
        if (!student || !klass) return [];
        return [{
          studentId: String(student._id),
          studentCode: student.studentCode,
          fullName: student.fullName,
          dateOfBirth: student.dateOfBirth,
          classId: enrollment.classId,
          classCode: klass.code,
          enrollmentId: String(enrollment._id),
        }];
      }),
      publishedClassIds: [...new Set(days.map((row) => row.classId))],
      schoolDay: resolveSchoolDay(date, calendarDay, year),
    };
  },
});

export const storePreviewInternal = internalMutation({
  args: {
    uploadId: v.string(),
    checksum: v.string(),
    rowCount: v.number(),
    matchedCount: v.number(),
    warningCount: v.number(),
    errorCount: v.number(),
    status: v.string(),
    rows: v.array(
      v.object({
        rowNumber: v.number(),
        rawStudentName: v.optional(v.string()),
        rawDateOfBirth: v.optional(v.string()),
        rawClassCode: v.optional(v.string()),
        rawObservedAt: v.optional(v.string()),
        rawStatus: v.optional(v.string()),
        matchedStudentId: v.optional(v.string()),
        matchedClassId: v.optional(v.string()),
        resolution: v.string(),
        messages: v.array(v.string()),
        normalizedObservedAt: v.optional(v.number()),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const id = ctx.db.normalizeId("attendanceImportUploads", args.uploadId);
    const upload = id ? await ctx.db.get(id) : null;
    if (!upload) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
    await assertAttendanceUploadActor(ctx, upload);
    if (upload.status === "published") throw new Error("ATTENDANCE_ALREADY_PUBLISHED");
    for (const row of await importRowsFor(ctx, args.uploadId)) await ctx.db.delete(row._id);
    const now = Date.now();
    for (const row of args.rows) {
      await ctx.db.insert("attendanceImportRows", { importId: args.uploadId, ...row, createdAt: now });
    }
    await ctx.db.patch(upload._id, {
      checksum: args.checksum,
      rowCount: args.rowCount,
      matchedCount: args.matchedCount,
      warningCount: args.warningCount,
      errorCount: args.errorCount,
      status: args.status,
      updatedAt: now,
    });
  },
});

export const REPLACE_MODES = [REPLACE_MODE_SUPPLEMENT, REPLACE_MODE_REPLACE, REPLACE_MODE_CANCEL];

async function publishStoredImport(
  ctx: MutationCtx,
  args: { uploadId: string; replaceMode?: string },
) {
  const id = ctx.db.normalizeId("attendanceImportUploads", args.uploadId);
  const upload = id ? await ctx.db.get(id) : null;
  if (!upload) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
  if (upload.status === "published") return { importId: args.uploadId, idempotent: true, published: true, count: 0, classCount: 0 };
  if (upload.sourceKind !== SCHOOL_SOURCE_KIND) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
  const { actor } = await assertAttendanceUploadActor(ctx, upload);
  if (upload.status !== "validated") throw new Error("IMPORT_ROWS_UNRESOLVED");
  if (args.replaceMode && !REPLACE_MODES.includes(args.replaceMode)) throw new Error("INVALID_REPLACE_MODE");

  const storedRows = await importRowsFor(ctx, args.uploadId);
  const byClass = new Map<string, typeof storedRows>();
  for (const row of storedRows) {
    if (!row.matchedClassId) continue;
    const list = byClass.get(row.matchedClassId) || [];
    list.push(row);
    byClass.set(row.matchedClassId, list);
  }
  const activeClasses = new Map(
    (await classesForYear(ctx, upload.schoolYearId))
      .filter((row) => row.status === "active")
      .map((row) => [String(row._id), row]),
  );
  const publishable = [...byClass.entries()]
    .filter(
      ([classId, rows]) => activeClasses.has(classId) && rows.length > 0 && rows.every((row) => row.resolution === "matched"),
    )
    .sort(([a], [b]) => compareClasses(activeClasses.get(a)!, activeClasses.get(b)!));
  if (!publishable.length) throw new Error("IMPORT_ROWS_UNRESOLVED");

  type Plan = { classId: string; rows: typeof storedRows; existing: Awaited<ReturnType<typeof daysForClassOnDate>> };
  const plans: Plan[] = [];
  const conflicts: string[] = [];
  for (const [classId, rows] of publishable) {
    const existing = await daysForClassOnDate(ctx, classId, upload.attendanceDate);
    if (existing.length) {
      const sourceIds = [...new Set(existing.map((row) => row.sourceImportId).filter(Boolean))] as string[];
      let sameFile = false;
      for (const sourceId of sourceIds) {
        const normalized = ctx.db.normalizeId("attendanceImportUploads", sourceId);
        const source = normalized ? await ctx.db.get(normalized) : null;
        if (source && source.checksum === upload.checksum) sameFile = true;
      }
      if (sameFile) continue;
      conflicts.push(classId);
    }
    plans.push({ classId, rows, existing });
  }
  if (conflicts.length && !args.replaceMode) throw new Error("ATTENDANCE_REPLACE_MODE_REQUIRED");

  const now = Date.now();
  let changedCount = 0;
  let classCount = 0;
  const skipped: string[] = [];
  for (const plan of plans) {
    const isConflict = plan.existing.length > 0;
    if (isConflict && args.replaceMode === REPLACE_MODE_CANCEL) {
      skipped.push(activeClasses.get(plan.classId)?.code || plan.classId);
      continue;
    }
    const roster = await enrollmentsForClassOnDate(ctx, plan.classId, upload.attendanceDate);
    const incoming = applyPublicationPolicy({
      enrollments: roster.map((row) => ({
        enrollmentId: String(row._id),
        studentId: row.studentId,
        classId: row.classId,
        schoolYearId: row.schoolYearId,
      })),
      matchedRows: plan.rows.map((row) => ({
        matchedStudentId: row.matchedStudentId,
        rawObservation: parseSchoolCameraStatus(row.rawStatus) || "unknown",
        normalizedObservedAt: row.normalizedObservedAt,
      })),
      presencePolicy: upload.presencePolicy,
      attendanceDate: upload.attendanceDate,
      sourceImportId: args.uploadId,
    });
    const writes = planAttendanceImportWrites({
      incomingDays: incoming.days,
      existingDays: plan.existing,
      mode: !isConflict ? "publish" : args.replaceMode === REPLACE_MODE_REPLACE ? "replace" : "supplement",
    });
    for (const day of writes.inserts) {
      await ctx.db.insert("studentAttendanceDays", {
        ...day,
        firstPublishedAt: now,
        updatedAt: now,
        updatedBy: actor.userId,
      });
    }
    for (const update of writes.updates) {
      const current = plan.existing.find((row) => row.studentId === update.studentId);
      if (!current) continue;
      const disposition =
        update.rawObservation === "absent" && update.disposition === "none" ? "pending" : update.disposition;
      await ctx.db.patch(current._id as Id<"studentAttendanceDays">, {
        rawObservation: update.rawObservation,
        rawObservedAt: update.rawObservedAt,
        sourceImportId: args.uploadId,
        disposition,
        effectiveStatus: disposition === update.disposition
          ? update.effectiveStatus
          : "absent_pending",
        updatedAt: now,
        updatedBy: actor.userId,
      });
    }
    changedCount += writes.changedCount;
    classCount += 1;
  }

  await ctx.db.patch(upload._id, { status: "published", publishedAt: now, updatedAt: now });
  await writeAudit(ctx, {
    actorUserId: actor.userId,
    action: "attendanceImport.publish",
    details: JSON.stringify({
      uploadId: args.uploadId,
      date: upload.attendanceDate,
      classCount,
      mode: args.replaceMode || "publish",
    }),
  });
  return {
    ...attendanceImportPublishResult({ uploadId: args.uploadId, changedCount }),
    classCount,
    skippedClassCodes: skipped,
  };
}
