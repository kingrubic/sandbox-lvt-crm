"use node";

import { createHash } from "node:crypto";
import { v } from "convex/values";
import * as XLSX from "xlsx";
import { internalAction } from "./_generated/server";
import {
  ATTENDANCE_IMPORT_MAX_BYTES,
  ATTENDANCE_IMPORT_MAX_SHEETS,
  rowsFromAttendanceMatrix,
} from "./attendanceImportSheet";

/** Reads the fixed school template from storage: first sheet whose header row matches wins. */
export const parseStorageXlsx = internalAction({
  args: { storageId: v.id("_storage") },
  handler: async (ctx, args) => {
    const blob = await ctx.storage.get(args.storageId);
    if (!blob) return { ok: false as const, message: "IMPORT_UPLOAD_NOT_FOUND" };
    const buffer = Buffer.from(await blob.arrayBuffer());
    if (!buffer.length) return { ok: false as const, message: "IMPORT_FILE_EMPTY" };
    if (buffer.length > ATTENDANCE_IMPORT_MAX_BYTES) return { ok: false as const, message: "IMPORT_FILE_TOO_LARGE" };
    let workbook: XLSX.WorkBook;
    try {
      workbook = XLSX.read(buffer, { type: "buffer", raw: false });
    } catch {
      return { ok: false as const, message: "INVALID_IMPORT_FILE" };
    }
    const checksum = createHash("sha256").update(buffer).digest("hex");
    let firstFailure: { message: string; missing?: string[] } | null = null;
    for (const sheetName of workbook.SheetNames.slice(0, ATTENDANCE_IMPORT_MAX_SHEETS)) {
      const matrix = XLSX.utils.sheet_to_json(workbook.Sheets[sheetName], {
        header: 1,
        defval: "",
        raw: false,
      }) as unknown[][];
      const parsed = rowsFromAttendanceMatrix(matrix);
      if (parsed.ok) {
        return { ok: true as const, checksum, sheetName, rows: parsed.rows };
      }
      if (!firstFailure || parsed.message !== "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND") {
        firstFailure = { message: parsed.message, missing: parsed.missing };
        if (parsed.message !== "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND") break;
      }
    }
    return {
      ok: false as const,
      message: firstFailure?.message || "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND",
      missing: firstFailure?.missing,
    };
  },
});
