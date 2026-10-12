import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  addIsoMonths as addIsoMonthsServer,
  dutyListDateWindow as dutyListDateWindowServer,
  dutyNotificationEndFloor,
  dutyOverlapsWindow,
  vietnamIsoDate as vietnamIsoDateServer,
} from '../convex/dutyRange.ts';
import {
  addIsoMonths,
  dutyListDateWindow,
  vietnamIsoDate,
} from '../src/duties/dutyListRange.js';

const dutiesSource = readFileSync(new URL('../convex/duties.ts', import.meta.url), 'utf8');
const reportsSource = readFileSync(new URL('../convex/reports.ts', import.meta.url), 'utf8');
const notificationsSource = readFileSync(new URL('../convex/notifications.ts', import.meta.url), 'utf8');
const rangeSource = readFileSync(new URL('../convex/dutyRange.ts', import.meta.url), 'utf8');
const personalSource = readFileSync(new URL('../src/reports/DutyReportsView.jsx', import.meta.url), 'utf8');
const mainSource = readFileSync(new URL('../src/main.jsx', import.meta.url), 'utf8');

test('list window matches on the client and server and stays bounded', () => {
  const now = Date.UTC(2026, 8, 23, 3, 0, 0);
  assert.equal(vietnamIsoDate(now), vietnamIsoDateServer(now));
  assert.equal(vietnamIsoDate(now), '2026-09-23');
  assert.equal(addIsoMonths('2026-03-31', -1), '2026-02-28');
  assert.equal(addIsoMonths('2026-01-31', -1), '2025-12-31');
  assert.equal(addIsoMonthsServer('2026-03-31', -1), addIsoMonths('2026-03-31', -1));
  const client = dutyListDateWindow(now);
  const server = dutyListDateWindowServer(now);
  assert.deepEqual(client, server);
  assert.equal(client.startDate, '2025-09-23');
  assert.equal(client.endDate, '2027-09-23');
  assert.ok(client.startDate <= client.endDate);
  assert.equal(dutyNotificationEndFloor(now), '2026-09-21');
});

test('overlap keeps duties that touch the window and drops the rest', () => {
  const window = { startDate: '2026-09-07', endDate: '2026-09-13' };
  assert.equal(
    dutyOverlapsWindow({ startDate: '2026-09-01', endDate: '2026-09-30' }, window.startDate, window.endDate),
    true,
  );
  assert.equal(
    dutyOverlapsWindow({ startDate: '2026-09-13', endDate: '2026-09-13' }, window.startDate, window.endDate),
    true,
  );
  assert.equal(
    dutyOverlapsWindow({ startDate: '2026-08-01', endDate: '2026-09-06' }, window.startDate, window.endDate),
    false,
  );
  assert.equal(
    dutyOverlapsWindow({ startDate: '2026-09-14', endDate: '2026-09-15' }, window.startDate, window.endDate),
    false,
  );
});

test('shared schedule and duty calendar read duties by the end-date index', () => {
  assert.match(rangeSource, /by_active_end/);
  assert.match(rangeSource, /gte\("endDate"/);
  assert.match(dutiesSource, /loadActiveDutiesOverlapping/);
  assert.match(dutiesSource, /loadDocsByIds/);
  assert.match(dutiesSource, /createdAt: duty\.createdAt/);
  assert.match(dutiesSource, /updatedAt: duty\.updatedAt/);
  assert.doesNotMatch(
    dutiesSource.slice(dutiesSource.indexOf('export const sharedSchedule')),
    /ctx\.db\.query\("duties"\)\.collect\(\)/,
  );
  const dutyCalendarSource = reportsSource.slice(
    reportsSource.indexOf('export const dutyCalendar'),
    reportsSource.indexOf('export const workCalendar'),
  );
  assert.match(dutyCalendarSource, /loadCalendarDuties/);
  assert.match(reportsSource, /loadPublicDutiesOverlapping/);
  assert.match(rangeSource, /by_published_end/);
  assert.match(dutyCalendarSource, /dutyListDateWindow/);
  assert.match(dutyCalendarSource, /loadAttendancesForDuties/);
  assert.match(reportsSource, /withIndex\("by_duty"/);
  assert.match(dutyCalendarSource, /createdAt: duty\.createdAt/);
  assert.match(dutyCalendarSource, /updatedAt: duty\.updatedAt/);
  assert.doesNotMatch(dutyCalendarSource, /query\("duties"\)\.collect\(\)/);
  assert.doesNotMatch(dutyCalendarSource, /query\("dutyAttendances"\)\.collect\(\)/);
  assert.doesNotMatch(dutyCalendarSource, /query\("users"\)\.collect\(\)/);
  assert.doesNotMatch(dutyCalendarSource, /unbounded/);
});

test('list mode always sends a date window and the bell does not poll every minute', () => {
  assert.match(personalSource, /dutyListDateWindow/);
  assert.match(personalSource, /startDate: listWindow \? listWindow\.startDate : toIsoDate\(calendarRange\.start\)/);
  assert.match(personalSource, /endDate: listWindow \? listWindow\.endDate : toIsoDate\(calendarRange\.end\)/);
  assert.doesNotMatch(personalSource, /mode === 'list'\s*\?\s*\{\}/);
  assert.doesNotMatch(mainSource, /useNotificationMinute/);
  assert.match(mainSource, /anyApi\.notifications\.feed,\s*canUseNotifications \? \{\} : 'skip'/);
  assert.match(mainSource, /duties\.listAdmin, editorOpen \? \{\} : 'skip'/);
  assert.match(mainSource, /duties\.listMine, editorOpen \? \{\} : 'skip'/);
  assert.match(notificationsSource, /by_created/);
  assert.match(notificationsSource, /loadPublicDutiesFromEndDate/);
  assert.match(notificationsSource, /CHAT_NOTIFICATION_TTL_MS/);
  assert.doesNotMatch(notificationsSource, /query\("workMessages"\)\.collect\(\)/);
  assert.doesNotMatch(notificationsSource, /query\("dutyMessages"\)\.collect\(\)/);
  assert.doesNotMatch(notificationsSource, /query\("duties"\)\.collect\(\)/);
});
