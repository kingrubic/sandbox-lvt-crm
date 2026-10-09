import assert from 'node:assert/strict';
import test from 'node:test';

import { groupHolidayRuns, lunarToSolar, schoolYearStats, suggestVietnamHolidays } from '../src/settings/schoolYearCalendar.js';

test('lunar → solar matches published Vietnamese calendar dates', () => {
  // Mùng 1 Tết
  assert.equal(lunarToSolar(1, 1, 2023), '2023-01-22');
  assert.equal(lunarToSolar(1, 1, 2024), '2024-02-10');
  assert.equal(lunarToSolar(1, 1, 2025), '2025-01-29');
  assert.equal(lunarToSolar(1, 1, 2026), '2026-02-17');
  assert.equal(lunarToSolar(1, 1, 2027), '2027-02-06');
  // Giỗ Tổ 10/3 — 2023 có tháng 2 nhuận nên kiểm tra luôn nhánh tháng nhuận
  assert.equal(lunarToSolar(10, 3, 2023), '2023-04-29');
  assert.equal(lunarToSolar(10, 3, 2024), '2024-04-18');
  assert.equal(lunarToSolar(10, 3, 2025), '2025-04-07');
});

test('suggestions stay inside the school year and are clipped to its bounds', () => {
  const list = suggestVietnamHolidays('2026-09-02', '2027-05-31');
  assert.deepEqual(
    list.map((item) => item.name),
    ['Nghỉ lễ Quốc khánh 2/9', 'Nghỉ Tết Dương lịch', 'Nghỉ Tết Nguyên đán', 'Giỗ Tổ Hùng Vương (10/3 âm lịch)', 'Nghỉ lễ 30/4 – 1/5'],
  );
  const quockhanh = list[0];
  assert.equal(quockhanh.from, '2026-09-02');
  assert.equal(quockhanh.to, '2026-09-02');
  const tet = list.find((item) => item.key === 'tet-2027');
  assert.equal(tet.from, '2027-02-04');
  assert.equal(tet.to, '2027-02-10');
  for (const item of list) {
    assert.ok(item.from >= '2026-09-02' && item.to <= '2027-05-31' && item.from <= item.to);
  }
});

test('holiday runs merge across weekends only when the note matches', () => {
  const runs = groupHolidayRuns([
    { date: '2027-02-05', kind: 'holiday', note: 'Tết' }, // Thứ 6
    { date: '2027-02-08', kind: 'holiday', note: 'Tết' }, // Thứ 2 — cuối tuần xen giữa
    { date: '2027-02-09', kind: 'holiday', note: 'Tết' },
    { date: '2027-02-10', kind: 'holiday', note: 'Khác' },
    { date: '2027-02-13', kind: 'extra_teaching', note: 'Học bù' },
    { date: '2027-02-16', kind: 'holiday', note: 'Khác' }, // cách 1 ngày thường → đợt mới
  ]);
  assert.deepEqual(runs.map((run) => [run.note, run.from, run.to, run.dates.length]), [
    ['Tết', '2027-02-05', '2027-02-09', 3],
    ['Khác', '2027-02-10', '2027-02-10', 1],
    ['Khác', '2027-02-16', '2027-02-16', 1],
  ]);
});

test('year stats count weekdays minus holidays plus make-up Saturdays', () => {
  const year = { startDate: '2026-09-07', endDate: '2026-09-20' }; // 2 tuần, 10 ngày thường
  const stats = schoolYearStats(year, [
    { date: '2026-09-08', kind: 'holiday' },
    { date: '2026-09-12', kind: 'extra_teaching' },
    { date: '2026-09-13', kind: 'holiday' }, // Chủ nhật: không tính là nghỉ lễ ngày thường
  ]);
  assert.deepEqual(stats, { schoolDays: 10, holidays: 1, extra: 1, weeks: 2 });
});

test('school-year writes are admin-only (Thiết lập tối cao)', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(new URL('../convex/schoolYears.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /homeroomCatalogWriterOrThrow/);
  const mutations = source.split(/export const \w+ = /).filter((chunk) => chunk.startsWith('mutation('));
  assert.ok(mutations.length >= 7);
  for (const chunk of mutations) assert.match(chunk, /await adminOrThrow\(ctx\)/);
});
