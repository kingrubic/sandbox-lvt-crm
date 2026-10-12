import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { projectPublicDuty } from "./dutyApproval";
import {
  currentUserOrThrow,
  isOperationalManagerRole,
  resolveUserMenuAccess,
} from "./lib";
import { isDutyParticipant, isWorkNotificationAssignee, isWorkReleased } from "./assignmentPolicy";
import { parseLocalMs } from "./dutyWritePolicy";
import { cleanPersonalReminderMilestones } from "./notificationSettings";
import {
  canEnableDutyPersonalReminder,
  canEnableWorkPersonalReminder,
  workCompletionBlocksReminder,
} from "./personalReminderPolicy";

const kindValidator = v.union(v.literal("duty"), v.literal("work"));
const sourceTypeValidator = v.union(
  v.literal("duty"),
  v.literal("department_work"),
  v.literal("personal_task"),
);

async function requireActiveUser(ctx: any) {
  const user = await currentUserOrThrow(ctx);
  if (user.status !== "active") throw new Error("USER_NOT_ACTIVE");
  if (user.mustChangePassword) throw new Error("PASSWORD_CHANGE_REQUIRED");
  return user;
}

async function requireMenu(ctx: any, menu: "duties" | "work") {
  const user = await requireActiveUser(ctx);
  if (isOperationalManagerRole(user.role)) return user;
  const menuAccess = await resolveUserMenuAccess(ctx, user);
  if ((menuAccess[menu] || "hidden") === "hidden") {
    throw new Error(`FORBIDDEN: ${menu} menu hidden`);
  }
  return user;
}

async function existingReminder(
  ctx: any,
  userId: string,
  kind: "duty" | "work",
  sourceId: string,
) {
  return await ctx.db
    .query("personalReminders")
    .withIndex("by_user_kind_source", (q: any) =>
      q.eq("userId", userId).eq("kind", kind).eq("sourceId", sourceId),
    )
    .unique();
}

async function assertDutyReminder(ctx: any, user: any, sourceId: string, enabling: boolean) {
  const duty = projectPublicDuty(await ctx.db.get(sourceId as Id<"duties">));
  const isParticipant = Boolean(duty && isDutyParticipant(user, duty));
  if (!enabling && isParticipant) return;
  const isOverdue = Boolean(duty && Date.now() > parseLocalMs(duty.endDate, duty.endTime));
  const error = canEnableDutyPersonalReminder({
    user,
    duty,
    isParticipant,
    isOverdue,
  });
  if (error) throw new Error(error);
}

async function assertWorkReminder(
  ctx: any,
  user: any,
  sourceType: "department_work" | "personal_task",
  sourceId: string,
  enabling: boolean,
) {
  const workItem = await ctx.db.get(sourceId as Id<"workItems">);
  if (workItem?.active) {
    const document = workItem.documentId
      ? await ctx.db.get(workItem.documentId as Id<"officeDocuments">)
      : null;
    const siblings = await ctx.db
      .query("workItems")
      .withIndex("by_document", (q: any) => q.eq("documentId", workItem.documentId))
      .collect();
    const excluded = new Set<string>();
    for (const sibling of siblings) {
      if (!sibling.active || sibling.assignmentType !== "individual") continue;
      for (const id of sibling.assigneeUserIds || []) excluded.add(String(id));
    }
    const expectedType = workItem.assignmentType === "individual" ? "personal_task" : "department_work";
    const isAssignee = Boolean(
      document &&
      isWorkReleased(document) &&
      expectedType === sourceType &&
      isWorkNotificationAssignee({
        user,
        item: workItem,
        document,
        excludedIndividualIds: excluded,
      }),
    );
    const blocked = workCompletionBlocksReminder({
      userId: String(user._id),
      completedUserIds: workItem.completedUserIds,
      completions: workItem.completions,
    });
    if (!enabling && isAssignee) return;
    const error = canEnableWorkPersonalReminder({
      found: true,
      isAssignee,
      blockedByCompletion: blocked,
    });
    if (error) throw new Error(error);
    return;
  }

  const task = await ctx.db.get(sourceId as Id<"personalTasks">);
  const isAssignee = Boolean(
    task?.active &&
    sourceType === "personal_task" &&
    (task.assigneeUserIds || []).some((id: string) => String(id) === String(user._id)),
  );
  const blocked = workCompletionBlocksReminder({
    userId: String(user._id),
    completedUserIds: task?.completedUserIds,
    completions: task?.completions,
  });
  if (!enabling && isAssignee) return;
  const error = canEnableWorkPersonalReminder({
    found: Boolean(task?.active),
    isAssignee,
    blockedByCompletion: blocked,
  });
  if (error) throw new Error(error);
}

export const listMine = query({
  args: { kind: v.optional(kindValidator) },
  handler: async (ctx, args) => {
    const user = await requireActiveUser(ctx);
    const rows = await ctx.db
      .query("personalReminders")
      .withIndex("by_user", (q) => q.eq("userId", String(user._id)))
      .collect();
    return {
      items: rows
        .filter((row) => !args.kind || row.kind === args.kind)
        .map((row) => ({
          sourceId: row.sourceId,
          sourceType: row.sourceType,
          enabled: row.enabled,
          milestonesHours: row.milestonesHours,
        })),
    };
  },
});

export const upsert = mutation({
  args: {
    kind: kindValidator,
    sourceType: sourceTypeValidator,
    sourceId: v.string(),
    enabled: v.boolean(),
    milestonesHours: v.array(v.number()),
  },
  handler: async (ctx, args) => {
    const sourceId = args.sourceId.trim();
    if (!sourceId || sourceId.length > 128) throw new Error("INVALID_SOURCE");
    if (args.kind === "duty" && args.sourceType !== "duty") {
      throw new Error("INVALID_SOURCE");
    }
    if (args.kind === "work" && args.sourceType === "duty") {
      throw new Error("INVALID_SOURCE");
    }
    const milestonesHours = cleanPersonalReminderMilestones(args.milestonesHours);
    const user = await requireMenu(ctx, args.kind === "duty" ? "duties" : "work");
    const current = await existingReminder(ctx, String(user._id), args.kind, sourceId);
    const now = Date.now();
    if (!args.enabled) {
      if (current) {
        await ctx.db.patch(current._id, {
          sourceType: args.sourceType,
          enabled: false,
          milestonesHours,
          updatedAt: now,
        });
      }
      return { sourceId, enabled: false, milestonesHours };
    }
    if (args.kind === "duty") {
      await assertDutyReminder(ctx, user, sourceId, args.enabled);
    } else {
      await assertWorkReminder(
        ctx,
        user,
        args.sourceType === "department_work" ? "department_work" : "personal_task",
        sourceId,
        args.enabled,
      );
    }
    if (current) {
      await ctx.db.patch(current._id, {
        sourceType: args.sourceType,
        enabled: args.enabled,
        milestonesHours,
        updatedAt: now,
      });
      return { sourceId, enabled: args.enabled, milestonesHours };
    }
    await ctx.db.insert("personalReminders", {
      userId: String(user._id),
      kind: args.kind,
      sourceType: args.sourceType,
      sourceId,
      enabled: args.enabled,
      milestonesHours,
      createdAt: now,
      updatedAt: now,
    });
    return { sourceId, enabled: args.enabled, milestonesHours };
  },
});
