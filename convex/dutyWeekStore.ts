import { activePositionLevel, isOperationalManagerRole } from "./lib";
import {
  dutyScopeForCreator,
  isDutyWeekReviewer,
  type DutyApprovalRow,
  type DutyWeekRecord,
} from "./dutyApproval";
import { loadDocsByIds } from "./dutyRange";

export async function loadDutyWeekRecord(ctx: { db: any }, weekStart: string): Promise<(DutyWeekRecord & { _id: any }) | null> {
  return await ctx.db
    .query("dutyWeeks")
    .withIndex("by_week", (q: any) => q.eq("weekStart", weekStart))
    .unique();
}

export async function loadDutyWeekRecords(ctx: { db: any }, firstWeek: string, lastWeek: string) {
  return (await ctx.db
    .query("dutyWeeks")
    .withIndex("by_week", (q: any) => q.gte("weekStart", firstWeek).lte("weekStart", lastWeek))
    .collect()) as Array<DutyWeekRecord & { _id: any }>;
}

/** Any edit pulls a submitted week back to draft so BGH never approves a moving target. */
export async function reopenSubmittedWeeks(ctx: { db: any }, weeks: string[], actorId: string, now: number) {
  for (const weekStart of weeks) {
    const record = await loadDutyWeekRecord(ctx, weekStart);
    if (record?.status !== "submitted") continue;
    await ctx.db.patch(record._id, { status: "draft", updatedBy: actorId, updatedAt: now });
  }
}

/**
 * Rows written before `scope` existed: a row created by admin/mod belongs to the
 * shared sheet, anything else was a team lead's own assignment.
 */
export async function resolveDutyScope(ctx: { db: any }, duty: DutyApprovalRow): Promise<"school" | "team"> {
  if (duty.scope === "school" || duty.scope === "team") return duty.scope;
  const [creator] = await loadDocsByIds(ctx, [duty.createdBy]);
  return dutyScopeForCreator(Boolean(creator && isOperationalManagerRole(String(creator.role || ""))));
}

export async function dutyViewerLevel(ctx: { db: any }, user: { positionId?: string }) {
  if (!user.positionId) return 0;
  const positions = await loadDocsByIds(ctx, [user.positionId]);
  return activePositionLevel(user, positions);
}

export async function isDutyWeekReviewerUser(ctx: { db: any }, user: { role?: string; status?: string; positionId?: string }) {
  return isDutyWeekReviewer(user, await dutyViewerLevel(ctx, user));
}

export async function listDutyWeekReviewerIds(ctx: { db: any }) {
  const [users, positions] = await Promise.all([
    ctx.db.query("users").collect(),
    ctx.db.query("positions").collect(),
  ]);
  return users
    .filter((user: any) => isDutyWeekReviewer(user, activePositionLevel(user, positions)))
    .map((user: any) => String(user._id));
}
