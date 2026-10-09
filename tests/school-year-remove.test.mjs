import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  SCHOOL_YEAR_DELETE_DEFAULT,
  SCHOOL_YEAR_DELETE_IN_USE,
  SCHOOL_YEAR_DELETE_LOCKED,
  SCHOOL_YEAR_USAGE_TABLES,
  schoolYearRemovalBlocker,
} from '../convex/homeroomCatalog.ts';
import { messageFor, SCHOOL_YEAR_USAGE_LABELS } from '../src/lib/appErrorMessage.js';

const schemaSource = readFileSync(new URL('../convex/schema.ts', import.meta.url), 'utf8');
const schoolYearsSource = readFileSync(new URL('../convex/schoolYears.ts', import.meta.url), 'utf8');
const settingsSource = readFileSync(new URL('../src/settings/SchoolYearSettings.jsx', import.meta.url), 'utf8');

test('năm học trống, không mặc định, chưa khóa thì xoá được', () => {
  assert.equal(schoolYearRemovalBlocker({ active: false }), null);
  assert.equal(schoolYearRemovalBlocker({ active: false }, []), null);
});

test('không xoá năm mặc định hoặc năm đã khóa (ưu tiên trước kiểm tra dữ liệu)', () => {
  assert.equal(schoolYearRemovalBlocker({ active: true }, ['homeroomClasses']), SCHOOL_YEAR_DELETE_DEFAULT);
  assert.equal(schoolYearRemovalBlocker({ active: false, lockedAt: 1 }), SCHOOL_YEAR_DELETE_LOCKED);
});

test('không xoá năm còn dữ liệu, mã lỗi liệt kê bảng theo thứ tự cố định', () => {
  assert.equal(
    schoolYearRemovalBlocker({ active: false }, ['studentAttendanceDays', 'homeroomClasses', 'otherTable']),
    `${SCHOOL_YEAR_DELETE_IN_USE}:homeroomClasses,studentAttendanceDays`,
  );
});

test('mọi bảng có schoolYearId (trừ lịch nghỉ của chính năm học) đều được kiểm tra trước khi xoá', () => {
  const tables = [];
  const re = /^  (\w+): defineTable\(\{([\s\S]*?)^  \}\)/gm;
  for (const match of schemaSource.matchAll(re)) {
    if (/\bschoolYearId:/.test(match[2])) tables.push(match[1]);
  }
  assert.ok(tables.includes('homeroomClasses'));
  assert.deepEqual(
    tables.filter((table) => table !== 'schoolCalendarDays').sort(),
    [...SCHOOL_YEAR_USAGE_TABLES].sort(),
  );
  for (const table of SCHOOL_YEAR_USAGE_TABLES) assert.ok(SCHOOL_YEAR_USAGE_LABELS[table], `thiếu nhãn cho ${table}`);
});

test('thông báo lỗi xoá năm học bằng tiếng Việt', () => {
  assert.match(messageFor(new Error(SCHOOL_YEAR_DELETE_DEFAULT)), /mặc định/);
  assert.match(messageFor(new Error(SCHOOL_YEAR_DELETE_LOCKED)), /đã khóa, không thể xoá/);
  assert.equal(
    messageFor(new Error(`[CONVEX M(schoolYears:remove)] Uncaught Error: ${SCHOOL_YEAR_DELETE_IN_USE}:homeroomClasses,classEnrollments`)),
    'Không thể xoá năm học vì đã có lớp chủ nhiệm, học sinh được xếp lớp. Chỉ xoá được năm học chưa có dữ liệu.',
  );
  assert.match(messageFor(SCHOOL_YEAR_DELETE_IN_USE), /Không thể xoá năm học/);
});

test('mutation remove chỉ cho Admin, xoá lịch nghỉ rồi mới xoá năm học', () => {
  const body = schoolYearsSource.slice(schoolYearsSource.indexOf('export const remove = mutation'));
  const handler = body.slice(0, body.indexOf('\n});'));
  assert.match(handler, /await adminOrThrow\(ctx\)/);
  assert.match(handler, /schoolYearRemovalBlocker\(year, await schoolYearUsage/);
  const deleteDays = handler.indexOf('for (const row of days) await ctx.db.delete(row._id)');
  const deleteYear = handler.indexOf('await ctx.db.delete(year._id)');
  assert.ok(deleteDays > 0 && deleteYear > deleteDays);
  assert.match(schoolYearsSource, /export const removalCheck = query\(\{[\s\S]*?await adminOrThrow\(ctx\)/);
});

test('form sửa năm học có nút Xoá năm học và bước xác nhận trong app (không dùng window.confirm)', () => {
  const modal = settingsSource.slice(settingsSource.indexOf('function YearFormModal'));
  assert.match(modal, /Xoá năm học/);
  assert.match(modal, /sy-delete-button hr-push-left/);
  assert.match(modal, /Xoá năm học \$\{year\.name\}\?/);
  assert.doesNotMatch(modal, /window\.confirm/);
  assert.match(modal, /year\.active \? 'SCHOOL_YEAR_DELETE_DEFAULT'/);
});
