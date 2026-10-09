import { v } from "convex/values";
import { mutation, query, type MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { assertSingleActiveEnrollment, enrollmentCoversDate } from "./homeroomCatalog";
import {
  assertClassReadable,
  homeroomActorOrThrow,
  homeroomCatalogWriterOrThrow,
  loadAssignments,
  writeAudit,
} from "./homeroomContext";
import {
  actorAssignedToStudentClass,
  assertGuardianBelongsToStudent,
  authorizeAccessibleEnrollments,
  canEditStudentContacts,
  canSeeSensitiveContacts,
  canWriteHomeroomCatalog,
  type HomeroomActor,
} from "./homeroomPolicy";
import { assertYmd, vietnamDateFromUtcMs } from "./homeroomTime";
import {
  activeGuardiansForStudent,
  enrollmentsForClassOnDate,
  enrollmentsForStudent,
  getClassById,
  getStudentById,
  studentsByIds,
} from "./homeroomData";

export const CONTACT_EDIT_FORBIDDEN = "CONTACT_EDIT_FORBIDDEN";
const PHONE_PATTERN = /^[0-9+().\-\s]{6,20}$/;
const GUARDIAN_RELATIONSHIPS = ["father", "mother", "guardian", "grandparent", "sibling", "other"];

function normalizeStudentCode(code: string) {
  return code.trim().toUpperCase();
}

function normalizePhone(value?: string) {
  const phone = value?.trim() || "";
  if (!phone) return undefined;
  if (!PHONE_PATTERN.test(phone)) throw new Error("INVALID_PHONE");
  return phone;
}

function normalizeName(value: string) {
  const name = value.trim().replace(/\s+/g, " ");
  if (!name || name.length > 120) throw new Error("INVALID_NAME");
  return name;
}

function optionalText(value: string | undefined, max: number) {
  const text = value?.trim() || "";
  if (text.length > max) throw new Error("INVALID_TEXT");
  return text || undefined;
}

export const listByClass = query({
  args: {
    classId: v.string(),
    date: v.optional(v.string()),
    includeSensitiveContacts: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    const date = args.date ? assertYmd(args.date) : vietnamDateFromUtcMs(Date.now());
    const klass = await assertClassReadable(ctx, actor, args.classId, date);
    const assignments = await loadAssignments(ctx, klass.schoolYearId);
    const enrollments = await enrollmentsForClassOnDate(ctx, args.classId, date);
    const showContacts = canSeeSensitiveContacts(actor, {
      assignedToClass: actorAssignedToStudentClass(
        actor,
        assignments,
        enrollments.map((row) => ({
          classId: row.classId,
          schoolYearId: row.schoolYearId,
          startDate: row.startDate,
          endDate: row.endDate,
        })),
      ),
    });
    const students = await studentsByIds(ctx, enrollments.map((row) => row.studentId));
    const rows = [];
    for (const enrollment of enrollments) {
      const student = students.get(enrollment.studentId);
      if (!student) continue;
      const guardians = showContacts ? await activeGuardiansForStudent(ctx, String(student._id)) : [];
      rows.push({
        enrollment: {
          _id: String(enrollment._id),
          rosterNumber: enrollment.rosterNumber,
          startDate: enrollment.startDate,
        },
        student: {
          _id: String(student._id),
          studentCode: student.studentCode,
          fullName: student.fullName,
          dateOfBirth: student.dateOfBirth,
          gender: student.gender,
          studentPhone: showContacts ? student.studentPhone : undefined,
        },
        guardians: guardians
          .slice()
          .sort((a, b) => Number(b.isPrimaryContact) - Number(a.isPrimaryContact))
          .map((row) => ({
            _id: String(row._id),
            fullName: row.fullName,
            relationship: row.relationship,
            phone: row.phone,
            isPrimaryContact: row.isPrimaryContact,
          })),
      });
    }
    rows.sort(
      (a, b) =>
        (a.enrollment.rosterNumber || 9999) - (b.enrollment.rosterNumber || 9999)
        || a.student.fullName.localeCompare(b.student.fullName, "vi"),
    );
    return { rows, showContacts };
  },
});

export const getScoped = query({
  args: { studentId: v.string(), includeSensitiveContacts: v.optional(v.boolean()) },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    if (!args.studentId || /\s/.test(args.studentId) || args.studentId.length > 64) {
      throw new Error("STUDENT_NOT_FOUND");
    }
    const student = await getStudentById(ctx, args.studentId);
    if (!student) throw new Error("STUDENT_NOT_FOUND");
    const enrollments = await enrollmentsForStudent(ctx, args.studentId);
    const assignments = await loadAssignments(ctx);
    const accessible = authorizeAccessibleEnrollments(actor, assignments, enrollments);
    const showContacts = canSeeSensitiveContacts(actor, {
      assignedToClass: actorAssignedToStudentClass(actor, assignments, accessible),
    });
    const today = vietnamDateFromUtcMs(Date.now());
    const currentClassIds = accessible.filter((row) => enrollmentCoversDate(row, today)).map((row) => row.classId);
    const guardians = showContacts ? await activeGuardiansForStudent(ctx, args.studentId) : [];
    const classes = new Map<string, { code: string; name: string; status: string }>();
    for (const row of accessible) {
      const klass = await getClassById(ctx, row.classId);
      if (klass) classes.set(row.classId, { code: klass.code, name: klass.name, status: klass.status });
    }
    return {
      student: {
        _id: String(student._id),
        studentCode: student.studentCode,
        fullName: student.fullName,
        dateOfBirth: student.dateOfBirth,
        gender: student.gender,
        status: student.status,
        studentPhone: showContacts ? student.studentPhone : undefined,
      },
      enrollments: accessible
        .slice()
        .sort((a, b) => b.startDate.localeCompare(a.startDate))
        .map((row) => ({
          _id: String(row._id),
          classId: row.classId,
          classCode: classes.get(row.classId)?.code || "",
          className: classes.get(row.classId)?.name || "",
          startDate: row.startDate,
          endDate: row.endDate,
          status: row.status,
          rosterNumber: row.rosterNumber,
          transferReason: row.transferReason,
          current: enrollmentCoversDate(row, today),
        })),
      guardians: guardians
        .slice()
        .sort((a, b) => Number(b.isPrimaryContact) - Number(a.isPrimaryContact))
        .map((row) => ({
          _id: String(row._id),
          fullName: row.fullName,
          relationship: row.relationship,
          phone: row.phone,
          isPrimaryContact: row.isPrimaryContact,
          notes: row.notes,
        })),
      showContacts,
      permissions: {
        canManage: canWriteHomeroomCatalog(actor),
        canEditContacts: canEditStudentContacts(actor, assignments, currentClassIds, today),
      },
    };
  },
});

async function assertContactEditor(ctx: MutationCtx, actor: HomeroomActor, studentId: string) {
  const student = await getStudentById(ctx, studentId);
  if (!student) throw new Error("STUDENT_NOT_FOUND");
  const today = vietnamDateFromUtcMs(Date.now());
  const current = (await enrollmentsForStudent(ctx, studentId)).filter((row) => enrollmentCoversDate(row, today));
  const assignments = await loadAssignments(ctx);
  const activeClassIds: string[] = [];
  for (const row of current) {
    const klass = await getClassById(ctx, row.classId);
    if (klass?.status === "active") activeClassIds.push(row.classId);
  }
  if (!canEditStudentContacts(actor, assignments, activeClassIds, today)) throw new Error(CONTACT_EDIT_FORBIDDEN);
  return student;
}

export const create = mutation({
  args: {
    classId: v.string(),
    studentCode: v.string(),
    fullName: v.string(),
    dateOfBirth: v.optional(v.string()),
    gender: v.optional(v.string()),
    studentPhone: v.optional(v.string()),
    rosterNumber: v.optional(v.number()),
    startDate: v.string(),
  },
  handler: async (ctx, args) => {
    const { user } = await homeroomCatalogWriterOrThrow(ctx);
    const klass = await getClassById(ctx, args.classId);
    if (!klass || klass.status !== "active") throw new Error("CLASS_NOT_FOUND");
    const studentCode = normalizeStudentCode(args.studentCode);
    if (!studentCode || studentCode.length > 30) throw new Error("INVALID_STUDENT_CODE");
    const fullName = normalizeName(args.fullName);
    const startDate = assertYmd(args.startDate);
    const dateOfBirth = args.dateOfBirth ? assertYmd(args.dateOfBirth) : undefined;
    const existing = await ctx.db
      .query("students")
      .withIndex("by_code", (q) => q.eq("studentCode", studentCode))
      .collect();
    if (existing.some((row) => row.status === "active")) throw new Error("STUDENT_CODE_EXISTS");
    const now = Date.now();
    const studentId = await ctx.db.insert("students", {
      studentCode,
      fullName,
      dateOfBirth,
      gender: optionalText(args.gender, 20),
      studentPhone: normalizePhone(args.studentPhone),
      status: "active",
      createdBy: String(user._id),
      createdAt: now,
      updatedAt: now,
    });
    assertSingleActiveEnrollment(await enrollmentsForStudent(ctx, String(studentId), klass.schoolYearId), {
      studentId: String(studentId),
      schoolYearId: klass.schoolYearId,
    });
    await ctx.db.insert("classEnrollments", {
      studentId: String(studentId),
      classId: args.classId,
      schoolYearId: klass.schoolYearId,
      rosterNumber: args.rosterNumber,
      startDate,
      status: "active",
      createdBy: String(user._id),
      createdAt: now,
      updatedAt: now,
    });
    await writeAudit(ctx, {
      actorUserId: String(user._id),
      action: "student.create",
      details: JSON.stringify({ studentId, classId: args.classId }),
    });
    return studentId;
  },
});

export const update = mutation({
  args: {
    id: v.string(),
    fullName: v.string(),
    dateOfBirth: v.optional(v.string()),
    gender: v.optional(v.string()),
    studentPhone: v.optional(v.string()),
    priorityCategory: v.optional(v.string()),
    ethnicity: v.optional(v.string()),
    hardshipNote: v.optional(v.string()),
    status: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const { user } = await homeroomCatalogWriterOrThrow(ctx);
    const current = await getStudentById(ctx, args.id);
    if (!current) throw new Error("STUDENT_NOT_FOUND");
    await ctx.db.patch(current._id, {
      fullName: normalizeName(args.fullName),
      dateOfBirth: args.dateOfBirth ? assertYmd(args.dateOfBirth) : undefined,
      gender: optionalText(args.gender, 20),
      studentPhone: normalizePhone(args.studentPhone),
      priorityCategory: optionalText(args.priorityCategory, 120),
      ethnicity: optionalText(args.ethnicity, 60),
      hardshipNote: optionalText(args.hardshipNote, 500),
      status: args.status || current.status,
      updatedBy: String(user._id),
      updatedAt: Date.now(),
    });
    await writeAudit(ctx, {
      actorUserId: String(user._id),
      action: "student.update",
      details: JSON.stringify({ studentId: args.id }),
    });
  },
});

/** GVCN của lớp hiện tại (hoặc Admin/Mod) cập nhật SĐT học sinh. */
export const updateContacts = mutation({
  args: { studentId: v.string(), studentPhone: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    const student = await assertContactEditor(ctx, actor, args.studentId);
    await ctx.db.patch(student._id, {
      studentPhone: normalizePhone(args.studentPhone),
      updatedBy: actor.userId,
      updatedAt: Date.now(),
    });
    await writeAudit(ctx, {
      actorUserId: actor.userId,
      action: "student.contacts",
      details: JSON.stringify({ studentId: args.studentId }),
    });
  },
});

export const upsertGuardian = mutation({
  args: {
    studentId: v.string(),
    guardianId: v.optional(v.string()),
    relationship: v.string(),
    fullName: v.string(),
    phone: v.optional(v.string()),
    isPrimaryContact: v.optional(v.boolean()),
    notes: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    await assertContactEditor(ctx, actor, args.studentId);
    const fullName = normalizeName(args.fullName);
    const relationship = GUARDIAN_RELATIONSHIPS.includes(args.relationship) ? args.relationship : "other";
    const phone = normalizePhone(args.phone);
    const notes = optionalText(args.notes, 300);
    const isPrimaryContact = Boolean(args.isPrimaryContact);
    const now = Date.now();
    const existing = await activeGuardiansForStudent(ctx, args.studentId);
    if (isPrimaryContact) {
      for (const row of existing) {
        if (row.isPrimaryContact && String(row._id) !== args.guardianId) {
          await ctx.db.patch(row._id, { isPrimaryContact: false, updatedBy: actor.userId, updatedAt: now });
        }
      }
    }
    let guardianId: string;
    if (args.guardianId) {
      const normalized = ctx.db.normalizeId("studentGuardians", args.guardianId);
      const current = normalized ? await ctx.db.get(normalized) : null;
      if (!current || !current.active) throw new Error("GUARDIAN_NOT_FOUND");
      assertGuardianBelongsToStudent(current, args.studentId);
      await ctx.db.patch(current._id, {
        relationship,
        fullName,
        phone,
        isPrimaryContact,
        notes,
        updatedBy: actor.userId,
        updatedAt: now,
      });
      guardianId = String(current._id);
    } else {
      if (existing.length >= 6) throw new Error("GUARDIAN_LIMIT");
      guardianId = String(
        await ctx.db.insert("studentGuardians", {
          studentId: args.studentId,
          relationship,
          fullName,
          phone,
          isPrimaryContact: isPrimaryContact || existing.length === 0,
          notes,
          active: true,
          createdBy: actor.userId,
          createdAt: now,
          updatedAt: now,
        }),
      );
    }
    await writeAudit(ctx, {
      actorUserId: actor.userId,
      action: args.guardianId ? "guardian.update" : "guardian.create",
      details: JSON.stringify({ studentId: args.studentId, guardianId }),
    });
    return guardianId as Id<"studentGuardians">;
  },
});

export const removeGuardian = mutation({
  args: { studentId: v.string(), guardianId: v.string() },
  handler: async (ctx, args) => {
    const { actor } = await homeroomActorOrThrow(ctx);
    await assertContactEditor(ctx, actor, args.studentId);
    const normalized = ctx.db.normalizeId("studentGuardians", args.guardianId);
    const current = normalized ? await ctx.db.get(normalized) : null;
    if (!current || !current.active) throw new Error("GUARDIAN_NOT_FOUND");
    assertGuardianBelongsToStudent(current, args.studentId);
    await ctx.db.patch(current._id, { active: false, isPrimaryContact: false, updatedBy: actor.userId, updatedAt: Date.now() });
    await writeAudit(ctx, {
      actorUserId: actor.userId,
      action: "guardian.remove",
      details: JSON.stringify({ studentId: args.studentId, guardianId: args.guardianId }),
    });
  },
});
