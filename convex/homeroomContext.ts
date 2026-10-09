import { currentUserOrThrow, resolveUserMenuAccess } from "./lib";
import {
  assertCanBulkImportRoster,
  assertCanListAttendanceImportClasses,
  assertCanReadClass,
  assertCanSupervisorImport,
  assertCanWriteHomeroomCatalog,
  assertClassNotArchived,
  assertHomeroomActorReady,
  type HomeroomActor,
  type HomeroomAssignment,
} from "./homeroomPolicy";
import { vietnamDateFromUtcMs } from "./homeroomTime";
import type { MutationCtx } from "./_generated/server";
import type { DbCtx } from "./lib";
import { getClassById, getYearById } from "./homeroomData";

export async function homeroomActorFromUser(
  ctx: DbCtx,
  user: { _id: string; role: string; status: string; mustChangePassword?: boolean },
): Promise<HomeroomActor> {
  const menuAccess = await resolveUserMenuAccess(ctx, user);
  return {
    userId: String(user._id),
    role: user.role,
    status: user.status,
    mustChangePassword: user.mustChangePassword,
    menuAccess,
  };
}

export async function homeroomActorOrThrow(ctx: DbCtx) {
  const user = await currentUserOrThrow(ctx);
  const actor = await homeroomActorFromUser(ctx, user);
  assertHomeroomActorReady(actor);
  return { user, actor };
}

export async function homeroomCatalogWriterOrThrow(ctx: DbCtx) {
  const user = await currentUserOrThrow(ctx);
  const actor = await homeroomActorFromUser(ctx, user);
  assertCanWriteHomeroomCatalog(actor);
  return { user, actor };
}

function toAssignment(row: {
  classId: string;
  schoolYearId: string;
  userId: string;
  assignmentType: string;
  scopeKind: string;
  effectiveFrom: string;
  effectiveTo?: string;
  active: boolean;
}): HomeroomAssignment {
  return {
    classId: row.classId,
    schoolYearId: row.schoolYearId,
    userId: row.userId,
    assignmentType: row.assignmentType,
    scopeKind: row.scopeKind,
    effectiveFrom: row.effectiveFrom,
    effectiveTo: row.effectiveTo,
    active: row.active,
  };
}

/** Assignments are a small table (≈ one row per class per GVCN change); the year index keeps it bounded. */
export async function loadAssignments(ctx: DbCtx, schoolYearId?: string): Promise<HomeroomAssignment[]> {
  const rows = schoolYearId
    ? await ctx.db
        .query("homeroomAssignments")
        .withIndex("by_year_user", (q) => q.eq("schoolYearId", schoolYearId))
        .collect()
    : await ctx.db.query("homeroomAssignments").collect();
  return rows.map(toAssignment);
}

/** Assignments of one user only — used for teacher-scoped checks. */
export async function loadUserAssignments(ctx: DbCtx, userId: string): Promise<HomeroomAssignment[]> {
  const rows = await ctx.db
    .query("homeroomAssignments")
    .withIndex("by_user_active", (q) => q.eq("userId", userId).eq("active", true))
    .collect();
  return rows.map(toAssignment);
}

export async function assertClassReadable(
  ctx: DbCtx,
  actor: HomeroomActor,
  classId: string,
  date = vietnamDateFromUtcMs(Date.now()),
) {
  const found = await getClassById(ctx, classId);
  if (!found) throw new Error("CLASS_NOT_FOUND");
  const assignments = await loadUserAssignments(ctx, actor.userId);
  assertCanReadClass(actor, assignments, String(found._id), date);
  return found;
}

export async function assertClassRosterWritable(
  ctx: DbCtx,
  actor: HomeroomActor,
  classId: string,
  date = vietnamDateFromUtcMs(Date.now()),
) {
  const found = await assertClassReadable(ctx, actor, classId, date);
  assertClassNotArchived(found);
  assertCanBulkImportRoster(actor);
  return found;
}

export async function assertClassSupervisor(
  ctx: DbCtx,
  actor: HomeroomActor,
  classId: string,
  date: string,
) {
  const found = await getClassById(ctx, classId);
  if (!found) throw new Error("CLASS_NOT_FOUND");
  assertClassNotArchived(found);
  assertCanSupervisorImport(actor, [], String(found._id), date);
  return found;
}

/** Whole-school camera import: Giám thị or Admin/Mod, for an existing school year. */
export async function assertAttendanceImporter(ctx: DbCtx, actor: HomeroomActor, schoolYearId: string) {
  assertCanListAttendanceImportClasses(actor);
  const year = await getYearById(ctx, schoolYearId);
  if (!year) throw new Error("SCHOOL_YEAR_NOT_FOUND");
  return year;
}

export async function writeAudit(
  ctx: MutationCtx,
  args: { actorUserId: string; action: string; details?: string; targetUserId?: string },
) {
  await ctx.db.insert("auditLogs", {
    actorUserId: args.actorUserId,
    action: args.action,
    targetUserId: args.targetUserId,
    details: args.details,
    at: Date.now(),
  });
}
