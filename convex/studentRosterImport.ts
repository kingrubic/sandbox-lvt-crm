import { v } from "convex/values";
import { anyApi } from "convex/server";
import { action, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { assertClassRosterWritable, homeroomActorOrThrow, writeAudit } from "./homeroomContext";
import { ENROLLMENT_YEAR_MISMATCH, assertSingleActiveEnrollment } from "./homeroomCatalog";
import { vietnamDateFromUtcMs } from "./homeroomTime";
import { ROSTER_IMPORT_MAX_BYTES, ROSTER_IMPORT_TTL_MS } from "./studentRosterImportSheet";
import {
  assertRosterUploadMatchesClass,
  assertStoredImportMetadata,
  findMatchingGuardian,
  validateRosterImportRows,
} from "./studentRosterImportValidate";
import { assertImportUploadUsable } from "./userImportPolicy";

const internal = anyApi;

async function loadRosterUploadOrThrow(
  ctx: { db: { get: (id: Id<"studentRosterImportUploads">) => Promise<any> } },
  uploadId: string,
) {
  if (!uploadId || /\s/.test(uploadId) || uploadId.length > 64) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
  let upload;
  try {
    upload = await ctx.db.get(uploadId as Id<"studentRosterImportUploads">);
  } catch {
    throw new Error("IMPORT_UPLOAD_NOT_FOUND");
  }
  if (!upload) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
  return upload;
}

async function assertRosterUploadActor(
  ctx: any,
  upload: { uploadedBy: string; status: string; expiresAt: number; classId: string; schoolYearId: string },
  args: { forCommit?: boolean } = {},
) {
  const { actor } = await homeroomActorOrThrow(ctx);
  assertImportUploadUsable(upload, { actorId: actor.userId, forCommit: args.forCommit });
  const klass = await assertClassRosterWritable(ctx, actor, upload.classId);
  assertRosterUploadMatchesClass(upload, klass);
  return { actor, klass };
}

export const generateUploadUrl = mutation({
  args: { classId: v.string() },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    const date = vietnamDateFromUtcMs(Date.now());
    await assertClassRosterWritable(ctx, actor, args.classId, date);
    return await ctx.storage.generateUploadUrl();
  },
});

export const registerUpload = mutation({
  args: {
    storageId: v.id("_storage"),
    fileName: v.string(),
    fileSize: v.number(),
    schoolYearId: v.string(),
    classId: v.string(),
    mode: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const { user, actor } = await homeroomActorOrThrow(ctx);
    const date = vietnamDateFromUtcMs(Date.now());
    const klass = await assertClassRosterWritable(ctx, actor, args.classId, date);
    if (klass.schoolYearId !== args.schoolYearId) throw new Error(ENROLLMENT_YEAR_MISMATCH);
    const stored = await ctx.db.system.get("_storage", args.storageId);
    assertStoredImportMetadata(stored, { fileSize: args.fileSize, maxBytes: ROSTER_IMPORT_MAX_BYTES });
    const fileName = args.fileName.trim();
    if (!fileName.toLowerCase().endsWith(".xlsx")) throw new Error("INVALID_IMPORT_FILE");
    const now = Date.now();
    const uploadId = await ctx.db.insert("studentRosterImportUploads", {
      storageId: args.storageId,
      fileName,
      fileSize: args.fileSize,
      uploadedBy: String(user._id),
      schoolYearId: args.schoolYearId,
      classId: args.classId,
      mode: args.mode === "merge" ? "merge" : "create",
      status: "uploaded",
      createdAt: now,
      expiresAt: now + ROSTER_IMPORT_TTL_MS,
    });
    await writeAudit(ctx, {
      actorUserId: String(user._id),
      action: "studentRoster.import_upload",
      details: JSON.stringify({ uploadId, classId: args.classId }),
    });
    return { uploadId, expiresAt: now + ROSTER_IMPORT_TTL_MS };
  },
});

export const getResult = query({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await loadRosterUploadOrThrow(ctx, args.uploadId);
    await assertRosterUploadActor(ctx, upload);
    const rows = await ctx.db
      .query("studentRosterImportRows")
      .withIndex("by_upload", (q) => q.eq("uploadId", args.uploadId))
      .collect();
    return {
      upload,
      rows: rows.map((row) => ({
        rowNumber: row.rowNumber,
        payload: JSON.parse(row.payload),
        issues: row.issues ? JSON.parse(row.issues) : [],
      })),
    };
  },
});

export const validateUpload = action({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await ctx.runQuery(internal.studentRosterImport.getUploadInternal, {
      uploadId: args.uploadId,
    });
    if (!upload) throw new Error("IMPORT_UPLOAD_NOT_FOUND");
    const parsed = await ctx.runAction(internal.studentRosterImportParse.parseStorageXlsx, {
      storageId: upload.storageId,
    });
    const context = await ctx.runQuery(internal.studentRosterImport.listStudentCodesInternal, {
      uploadId: args.uploadId,
    });
    const result = parsed.ok
      ? validateRosterImportRows(parsed.rows, {
          mode: upload.mode,
          existingStudentCodes: context.existingStudentCodes,
          existingEnrollments: context.existingEnrollments,
          targetClassId: upload.classId,
          targetSchoolYearId: upload.schoolYearId,
        })
      : {
          ok: false,
          issues: [
            {
              rowNumber: 0,
              field: "file",
              column: "",
              rejectedValue: null,
              code: parsed.message || "INVALID_IMPORT_FILE",
              message: "Không đọc được file danh sách học sinh.",
              severity: "error" as const,
            },
          ],
          blockers: [],
          preview: [],
        };
    const blockers = result.issues.filter((item) => item.severity === "error");
    await ctx.runMutation(internal.studentRosterImport.storeValidationInternal, {
      uploadId: args.uploadId,
      status: blockers.length ? "rejected" : "validated",
      rowCount: parsed.ok ? parsed.rows.length : 0,
      errorCount: blockers.length,
      successCount: result.preview.length,
      rows: (parsed.ok ? parsed.rows : []).map((row: { rowNumber: number }) => ({
        rowNumber: row.rowNumber,
        payload: JSON.stringify(row),
        issues: JSON.stringify(result.issues.filter((item) => item.rowNumber === row.rowNumber)),
      })),
    });
    return { ...result, blockers, ok: blockers.length === 0 };
  },
});

export const commit = action({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const validated = await ctx.runAction(internal.studentRosterImport.validateUpload, {
      uploadId: args.uploadId,
    });
    if (!validated.ok) throw new Error("IMPORT_VALIDATION_FAILED");
    return await ctx.runMutation(internal.studentRosterImport.commitValidatedInternal, {
      uploadId: args.uploadId,
    });
  },
});

export const getUploadInternal = internalQuery({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await loadRosterUploadOrThrow(ctx, args.uploadId);
    await assertRosterUploadActor(ctx, upload);
    return upload;
  },
});

export const listStudentCodesInternal = internalQuery({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await loadRosterUploadOrThrow(ctx, args.uploadId);
    await assertRosterUploadActor(ctx, upload);
    const students = (await ctx.db.query("students").collect()).filter((row) => row.status === "active");
    const enrollments = await ctx.db.query("classEnrollments").collect();
    const byId = new Map(students.map((row) => [String(row._id), row]));
    return {
      existingStudentCodes: students.map((row) => row.studentCode),
      existingEnrollments: enrollments
        .map((row) => {
          const student = byId.get(row.studentId);
          return student
            ? {
                studentCode: student.studentCode,
                classId: row.classId,
                schoolYearId: row.schoolYearId,
                status: row.status,
              }
            : null;
        })
        .filter(Boolean),
    };
  },
});

export const storeValidationInternal = internalMutation({
  args: {
    uploadId: v.string(),
    status: v.string(),
    rowCount: v.number(),
    errorCount: v.number(),
    successCount: v.number(),
    rows: v.array(v.object({ rowNumber: v.number(), payload: v.string(), issues: v.string() })),
  },
  handler: async (ctx, args) => {
    const upload = await loadRosterUploadOrThrow(ctx, args.uploadId);
    await assertRosterUploadActor(ctx, upload);
    if (upload.status === "committed" || upload.status === "committing") {
      throw new Error("IMPORT_UPLOAD_ALREADY_COMMITTED");
    }
    const existing = await ctx.db
      .query("studentRosterImportRows")
      .withIndex("by_upload", (q) => q.eq("uploadId", args.uploadId))
      .collect();
    for (const row of existing) await ctx.db.delete(row._id);
    const now = Date.now();
    for (const row of args.rows) {
      await ctx.db.insert("studentRosterImportRows", {
        uploadId: args.uploadId,
        rowNumber: row.rowNumber,
        payload: row.payload,
        issues: row.issues,
        createdAt: now,
      });
    }
    await ctx.db.patch(upload._id, {
      status: args.status,
      rowCount: args.rowCount,
      errorCount: args.errorCount,
      successCount: args.successCount,
    });
  },
});

export const commitValidatedInternal = internalMutation({
  args: { uploadId: v.string() },
  handler: async (ctx, args) => {
    const upload = await loadRosterUploadOrThrow(ctx, args.uploadId);
    await assertRosterUploadActor(ctx, upload, { forCommit: true });
    if (upload.status === "committed") return { uploadId: args.uploadId, alreadyCommitted: true };
    if (upload.status === "committing") throw new Error("IMPORT_UPLOAD_IN_PROGRESS");
    if (upload.status !== "validated") throw new Error("IMPORT_VALIDATION_FAILED");
    const stored = await ctx.db
      .query("studentRosterImportRows")
      .withIndex("by_upload", (q) => q.eq("uploadId", args.uploadId))
      .collect();
    const sheetRows = stored.map((row) => JSON.parse(row.payload));
    const students = (await ctx.db.query("students").collect()).filter((row) => row.status === "active");
    const enrollments = await ctx.db.query("classEnrollments").collect();
    const byId = new Map(students.map((row) => [String(row._id), row]));
    const result = validateRosterImportRows(sheetRows, {
      mode: upload.mode,
      existingStudentCodes: students.map((row) => row.studentCode),
      existingEnrollments: enrollments
        .map((row) => {
          const student = byId.get(row.studentId);
          return student
            ? {
                studentCode: student.studentCode,
                classId: row.classId,
                schoolYearId: row.schoolYearId,
                status: row.status,
              }
            : null;
        })
        .filter((row): row is { studentCode: string; classId: string; schoolYearId: string; status: string } =>
          Boolean(row),
        ),
      targetClassId: upload.classId,
      targetSchoolYearId: upload.schoolYearId,
    });
    if (!result.ok) throw new Error("IMPORT_VALIDATION_FAILED");
    const now = Date.now();
    await ctx.db.patch(upload._id, { status: "committing" });
    const guardians = await ctx.db.query("studentGuardians").collect();
    for (const row of result.preview) {
      const existing = students.find((student) => student.studentCode === row.studentCode);
      let studentId = existing ? String(existing._id) : "";
      if (existing && upload.mode === "create") throw new Error("STUDENT_CODE_EXISTS");
      if (existing && upload.mode === "merge") {
        studentId = String(existing._id);
        await ctx.db.patch(existing._id, {
          fullName: row.fullName,
          dateOfBirth: row.dateOfBirth,
          gender: row.gender,
          studentPhone: row.studentPhone,
          priorityCategory: row.priorityCategory,
          ethnicity: row.ethnicity,
          hardshipNote: row.hardshipNote,
          updatedBy: upload.uploadedBy,
          updatedAt: now,
        });
      } else {
        studentId = String(
          await ctx.db.insert("students", {
            studentCode: row.studentCode,
            fullName: row.fullName,
            dateOfBirth: row.dateOfBirth,
            gender: row.gender,
            studentPhone: row.studentPhone,
            priorityCategory: row.priorityCategory,
            ethnicity: row.ethnicity,
            hardshipNote: row.hardshipNote,
            status: "active",
            createdBy: upload.uploadedBy,
            createdAt: now,
            updatedAt: now,
          }),
        );
      }
      const already = enrollments.find(
        (item) => item.studentId === studentId && item.schoolYearId === upload.schoolYearId && item.status === "active",
      );
      if (already && already.classId !== upload.classId) throw new Error("STUDENT_ENROLLED_OTHER_CLASS");
      if (already && already.schoolYearId !== upload.schoolYearId) throw new Error(ENROLLMENT_YEAR_MISMATCH);
      if (!already) {
        assertSingleActiveEnrollment(enrollments, {
          studentId,
          schoolYearId: upload.schoolYearId,
        });
        await ctx.db.insert("classEnrollments", {
          studentId,
          classId: upload.classId,
          schoolYearId: upload.schoolYearId,
          rosterNumber: row.rosterNumber,
          startDate: vietnamDateFromUtcMs(now),
          status: "active",
          createdBy: upload.uploadedBy,
          createdAt: now,
          updatedAt: now,
        });
      }
      const currentGuardians = guardians.filter((item) => item.studentId === studentId && item.active);
      for (const guardian of row.guardians || []) {
        if (findMatchingGuardian(currentGuardians, guardian)) continue;
        const inserted = await ctx.db.insert("studentGuardians", {
          studentId,
          relationship: guardian.relationship,
          fullName: guardian.fullName,
          phone: guardian.phone,
          isPrimaryContact: Boolean(guardian.isPrimaryContact),
          active: true,
          createdBy: upload.uploadedBy,
          createdAt: now,
          updatedAt: now,
        });
        currentGuardians.push({
          _id: inserted,
          studentId,
          relationship: guardian.relationship,
          fullName: guardian.fullName,
          active: true,
        } as (typeof currentGuardians)[number]);
      }
    }
    await ctx.db.patch(upload._id, {
      status: "committed",
      committedAt: now,
      successCount: result.preview.length,
    });
    await writeAudit(ctx, {
      actorUserId: upload.uploadedBy,
      action: "studentRoster.import_commit",
      details: JSON.stringify({ uploadId: args.uploadId, count: result.preview.length }),
    });
    return { uploadId: args.uploadId, committed: true, count: result.preview.length };
  },
});
