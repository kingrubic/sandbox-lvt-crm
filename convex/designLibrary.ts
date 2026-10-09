import { query } from "./_generated/server";
import { adminOrThrow } from "./lib";

/**
 * Gate for the internal UI component library page served by the production
 * file gateway (`/api/design-library`). Administrator only.
 */
export const authorizeView = query({
  args: {},
  handler: async (ctx) => {
    await adminOrThrow(ctx);
    return { allowed: true as const };
  },
});
