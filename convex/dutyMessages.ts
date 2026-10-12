import { v } from "convex/values";
import { internal } from "./_generated/api";
import { mutation, query } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { dutyListTitle, isDutyParticipant } from "./assignmentPolicy";
import {
  buildChatNotificationItem,
  canRecallChatMessage,
  evaluateChatRecall,
  isChatMessageRecalled,
  recallErrorCode,
} from "./chatMessagePolicy";
import { deactivateChatNotificationEvents, insertChatNotificationEvents } from "./chatNotifications";
import { requireDutiesAccess } from "./duties";
import { isOperationalManagerRole, isSameDepartmentSubordinate, resolveUserMenuAccess } from "./lib";
import { canAccessDutyChat, prepareDutyMessageBody } from "./dutyMessagePolicy";
import { projectPublicDuty } from "./dutyApproval";
import { sanitizeWorkMessageHtml, workChatAuthorInitials } from "./workMessagePolicy";
import { listDutyChatRecipientIds } from "./chatAudience";
import { applyChatRecall, publishChatMessage } from "./chatInbox";
import { clampChatPageLimit } from "./chatHubPolicy";

async function loadDuty(ctx: any, dutyId: string) {
  try {
    return await ctx.db.get(dutyId as Id<"duties">);
  } catch {
    return null;
  }
}

async function authorizeDutyChat(ctx: any, dutyId: string) {
  const { user, access, isAdmin } = await requireDutiesAccess(ctx);
  const raw = await loadDuty(ctx, String(dutyId || ""));
  // Chat on a row BGH has not approved stays with văn thư.
  const duty = isAdmin ? raw : projectPublicDuty(raw);
  const users = await ctx.db.query("users").collect();
  const positions = await ctx.db.query("positions").collect();
  const subordinateUsers = isAdmin
    ? []
    : users.filter(
        (target: any) =>
          target.status === "active" && isSameDepartmentSubordinate(user, target, positions),
      );
  const allowed = canAccessDutyChat({
    actorUserId: String(user._id),
    actorRole: String(user.role || ""),
    actorAccess: String(access || ""),
    actorDepartmentId: user.departmentId,
    duty,
    subordinateUsers,
  });
  if (!allowed || !duty) throw new Error("DUTY_CHAT_FORBIDDEN");
  const usersById = new Map<string, { status?: string; name?: string; email?: string }>(
    users.map((row: any) => [String(row._id), row]),
  );
  return { user, duty, usersById };
}

function displayName(user: { name?: string; email?: string } | null | undefined) {
  const name = String(user?.name || "").trim();
  if (name) return name;
  const email = String(user?.email || "").trim();
  if (email) return email;
  return "Người dùng";
}

export const list = query({
  args: {
    dutyId: v.string(),
    before: v.optional(v.number()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const { user, duty, usersById } = await authorizeDutyChat(ctx, args.dutyId);
    const limit = clampChatPageLimit(args.limit);
    const rows = await ctx.db
      .query("dutyMessages")
      .withIndex("by_duty_created", (q: any) => {
        const range = q.eq("dutyId", String(args.dutyId));
        return args.before ? range.lt("createdAt", args.before) : range;
      })
      .order("desc")
      .take(limit + 1);
    const hasMore = rows.length > limit;
    const now = Date.now();
    const messages = [...rows]
      .slice(0, limit)
      .filter((row: any) => row.active)
      .reverse()
      .map((row: any) => {
        const author = usersById.get(String(row.authorUserId));
        const authorName = displayName(author);
        const recalled = isChatMessageRecalled(row);
        const isSelf = String(row.authorUserId) === String(user._id);
        return {
          _id: row._id,
          authorUserId: row.authorUserId,
          authorName,
          authorInitials: workChatAuthorInitials(authorName),
          bodyHtml: recalled ? "" : sanitizeWorkMessageHtml(row.bodyHtml),
          createdAt: row.createdAt,
          recalled,
          canRecall: canRecallChatMessage({
            actorUserId: String(user._id),
            authorUserId: String(row.authorUserId),
            createdAt: row.createdAt,
            recalledAt: row.recalledAt,
            now,
          }),
          isSelf,
        };
      });
    return {
      dutyId: String(duty._id),
      dutyTitle: dutyListTitle(duty),
      currentUserId: String(user._id),
      isParticipant: isDutyParticipant(user, duty),
      hasMore,
      messages,
    };
  },
});

export const create = mutation({
  args: {
    dutyId: v.string(),
    bodyHtml: v.string(),
  },
  handler: async (ctx, args) => {
    const { user, duty, usersById } = await authorizeDutyChat(ctx, args.dutyId);
    const prepared = prepareDutyMessageBody(args.bodyHtml);
    const now = Date.now();
    const messageId = await ctx.db.insert("dutyMessages", {
      dutyId: String(args.dutyId),
      authorUserId: String(user._id),
      bodyHtml: prepared.bodyHtml,
      bodyText: prepared.bodyText,
      active: true,
      createdAt: now,
      updatedAt: now,
    });
    const users = [...usersById.values()] as any[];
    const positions = await ctx.db.query("positions").collect();
    const recipientIds = await listDutyChatRecipientIds(ctx, {
      authorUserId: String(user._id),
      duty,
      users,
      positions,
    });
    await publishChatMessage(ctx, {
      kind: "duty",
      entityId: String(args.dutyId),
      title: dutyListTitle(duty),
      bodyText: prepared.bodyText,
      createdAt: now,
      authorUserId: String(user._id),
      recipientIds,
    });
    if (recipientIds.length) {
      const feedItem = buildChatNotificationItem({
        kind: "duty",
        messageId: String(messageId),
        entityId: String(args.dutyId),
        entityTitle: dutyListTitle(duty),
        authorName: displayName(user),
        bodyText: prepared.bodyText,
        createdAt: now,
      });
      await insertChatNotificationEvents(ctx, {
        recipientUserIds: recipientIds,
        kind: "duty",
        sourceId: String(args.dutyId),
        messageId: String(messageId),
        title: feedItem.title,
        description: feedItem.description,
        createdAt: now,
      });
      await ctx.scheduler.runAfter(0, internal.pushActions.sendToUsers, {
        userIds: recipientIds,
        title: feedItem.title,
        body: feedItem.description,
        kind: "duty",
        sourceType: "duty_chat",
        sourceId: String(args.dutyId),
      });
    }
    return { messageId };
  },
});

export const recall = mutation({
  args: { messageId: v.string() },
  handler: async (ctx, args) => {
    let row = null;
    try {
      row = await ctx.db.get(args.messageId as Id<"dutyMessages">);
    } catch {
      row = null;
    }
    if (!row?.active) throw new Error("DUTY_CHAT_RECALL_FORBIDDEN");
    const { user } = await authorizeDutyChat(ctx, String(row.dutyId));
    const decision = evaluateChatRecall({
      actorUserId: String(user._id),
      authorUserId: String(row.authorUserId),
      createdAt: row.createdAt,
      recalledAt: row.recalledAt,
    });
    if (!decision.ok) throw new Error(recallErrorCode("duty", decision.code));
    const now = Date.now();
    await ctx.db.patch(row._id, { recalledAt: now, updatedAt: now });
    await deactivateChatNotificationEvents(ctx, String(row._id));
    await applyChatRecall(ctx, {
      kind: "duty",
      entityId: String(row.dutyId),
      messageCreatedAt: row.createdAt,
      authorUserId: String(row.authorUserId),
    });
    return { recalled: true };
  },
});
