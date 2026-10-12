import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { dutyScheduleRevision } from '../convex/dutyRange.ts';
import {
  DUTY_SCHEDULE_CACHE_TTL_MS,
  createMemoryDutyScheduleStore,
  displayedDutySchedule,
  dutyEventTiming,
  dutyScheduleCacheKey,
  isDutyScheduleCacheFresh,
  planDutyScheduleRead,
  readDutyScheduleEntry,
  refreshCachedDutyCalendar,
  writeDutyScheduleEntry,
} from '../src/duties/dutyScheduleCache.js';

const dutiesSource = readFileSync(new URL('../convex/duties.ts', import.meta.url), 'utf8');
const reportsSource = readFileSync(new URL('../convex/reports.ts', import.meta.url), 'utf8');
const sharedView = readFileSync(new URL('../src/duties/SharedDutyScheduleView.jsx', import.meta.url), 'utf8');
const personalView = readFileSync(new URL('../src/reports/DutyReportsView.jsx', import.meta.url), 'utf8');
const hookSource = readFileSync(new URL('../src/duties/useCachedDutySchedule.js', import.meta.url), 'utf8');
const cacheSource = readFileSync(new URL('../src/duties/dutyScheduleCache.js', import.meta.url), 'utf8');

const NOW = Date.UTC(2026, 8, 23, 3, 0, 0);

function entry(overrides = {}) {
  return {
    key: 'user-a\u001fshared\u001fweek\u001f2026-09-21\u001f2026-09-27\u001f',
    userId: 'user-a',
    view: 'shared',
    revision: 'rev-1',
    storedAt: NOW - 60_000,
    data: { events: [{ _id: 'duty-1', title: 'Họp' }], revision: 'rev-1' },
    ...overrides,
  };
}

test('duty window revision changes when any row changes, not only the newest', () => {
  const base = [
    { _id: 'a', updatedAt: 100 },
    { _id: 'b', updatedAt: 50 },
  ];
  const original = dutyScheduleRevision({ duties: base });
  const reordered = dutyScheduleRevision({
    duties: [
      { _id: 'b', updatedAt: 50 },
      { _id: 'a', updatedAt: 100 },
    ],
  });
  assert.equal(reordered, original);
  assert.notEqual(
    dutyScheduleRevision({
      duties: [
        { _id: 'a', updatedAt: 100 },
        { _id: 'b', updatedAt: 80 },
      ],
    }),
    original,
  );
  assert.notEqual(dutyScheduleRevision({ duties: [base[0]] }), original);
  assert.notEqual(
    dutyScheduleRevision({
      duties: base,
      attendances: [{ dutyId: 'a', userId: 'u', status: 'pending', updatedAt: 40 }],
    }),
    original,
  );
  assert.notEqual(
    dutyScheduleRevision({
      duties: base,
      attendances: [{ dutyId: 'a', userId: 'u', status: 'attended', updatedAt: 40 }],
    }),
    dutyScheduleRevision({
      duties: base,
      attendances: [{ dutyId: 'a', userId: 'u', status: 'pending', updatedAt: 40 }],
    }),
  );
  assert.notEqual(
    dutyScheduleRevision({ duties: base, meta: 'confirm' }),
    dutyScheduleRevision({ duties: base, meta: 'noconfirm' }),
  );
});

test('cache key is scoped by user, view, mode, window, and selected person', () => {
  const shared = dutyScheduleCacheKey({
    userId: 'user-a',
    view: 'shared',
    mode: 'week',
    startDate: '2026-09-21',
    endDate: '2026-09-27',
  });
  assert.notEqual(shared, dutyScheduleCacheKey({
    userId: 'user-b',
    view: 'shared',
    mode: 'week',
    startDate: '2026-09-21',
    endDate: '2026-09-27',
  }));
  assert.notEqual(shared, dutyScheduleCacheKey({
    userId: 'user-a',
    view: 'personal',
    mode: 'week',
    startDate: '2026-09-21',
    endDate: '2026-09-27',
    selectedUserId: 'user-a',
  }));
  assert.notEqual(shared, dutyScheduleCacheKey({
    userId: 'user-a',
    view: 'shared',
    mode: 'month',
    startDate: '2026-09-21',
    endDate: '2026-09-27',
  }));
  assert.equal(DUTY_SCHEDULE_CACHE_TTL_MS, 24 * 60 * 60 * 1000);
});

test('fresh cache is a hit, expiry and a new stamp both refetch', async () => {
  const store = createMemoryDutyScheduleStore();
  const saved = await writeDutyScheduleEntry(store, entry(), NOW);
  assert.equal(saved.revision, 'rev-1');
  assert.equal(isDutyScheduleCacheFresh(saved, NOW), true);

  const loaded = await readDutyScheduleEntry(store, saved.key, NOW);
  assert.equal(loaded.data.events[0].title, 'Họp');
  const atTtl = entry({ storedAt: NOW });
  assert.equal(isDutyScheduleCacheFresh(atTtl, NOW + DUTY_SCHEDULE_CACHE_TTL_MS), true);
  assert.equal(isDutyScheduleCacheFresh(atTtl, NOW + DUTY_SCHEDULE_CACHE_TTL_MS + 1), false);
  assert.equal(await readDutyScheduleEntry(store, saved.key, NOW + DUTY_SCHEDULE_CACHE_TTL_MS + 1), null);

  const hit = planDutyScheduleRead({
    enabled: true,
    checked: true,
    entry: saved,
    revision: 'rev-1',
    now: NOW,
  });
  assert.equal(hit.source, 'cache');
  assert.equal(hit.fetchLive, false);
  assert.equal(hit.fetchRevision, true);
  assert.equal(displayedDutySchedule(hit, undefined, saved).revision, 'rev-1');

  const waiting = planDutyScheduleRead({
    enabled: true,
    checked: true,
    entry: saved,
    revision: undefined,
    now: NOW,
  });
  assert.equal(waiting.fetchLive, false);
  assert.equal(waiting.fetchRevision, true);
  assert.equal(displayedDutySchedule(waiting, undefined, saved).events.length, 1);

  const mismatch = planDutyScheduleRead({
    enabled: true,
    checked: true,
    entry: saved,
    revision: 'rev-2',
    now: NOW,
  });
  assert.equal(mismatch.source, 'cache-then-live');
  assert.equal(mismatch.fetchLive, true);
  assert.equal(displayedDutySchedule(mismatch, undefined, saved).revision, 'rev-1');
  assert.equal(displayedDutySchedule(mismatch, { revision: 'rev-2', events: [] }, saved).revision, 'rev-2');

  const expired = planDutyScheduleRead({
    enabled: true,
    checked: true,
    entry: { ...saved, storedAt: NOW - DUTY_SCHEDULE_CACHE_TTL_MS - 1 },
    revision: 'rev-1',
    now: NOW,
  });
  assert.equal(expired.source, 'live');
  assert.equal(expired.fetchRevision, false);
  assert.equal(expired.fetchLive, true);

  const cold = planDutyScheduleRead({
    enabled: true,
    checked: false,
    entry: null,
    revision: undefined,
    now: NOW,
  });
  assert.equal(cold.source, 'pending');
  assert.equal(cold.fetchLive, false);

  const signedOut = planDutyScheduleRead({
    enabled: false,
    checked: true,
    entry: saved,
    revision: 'rev-1',
    now: NOW,
  });
  assert.equal(signedOut.fetchLive, true);
  assert.equal(signedOut.fetchRevision, false);
});

test('writing cache drops other users and expired windows', async () => {
  const store = createMemoryDutyScheduleStore();
  const other = entry({
    key: 'user-b\u001fshared\u001fweek\u001f2026-09-21\u001f2026-09-27\u001f',
    userId: 'user-b',
  });
  const stale = entry({
    key: 'user-a\u001fshared\u001fmonth\u001f2026-09-01\u001f2026-09-30\u001f',
    storedAt: NOW - DUTY_SCHEDULE_CACHE_TTL_MS - 5,
  });
  await store.put(other);
  await store.put(stale);
  await writeDutyScheduleEntry(store, entry(), NOW);
  const keys = (await store.entries()).map((row) => row.key);
  assert.deepEqual(keys, [entry().key]);

  const current = entry();
  const leftover = entry({
    key: 'user-b\u001fpersonal\u001flist\u001f2025-09-23\u001f2027-09-23\u001fuser-b',
    userId: 'user-b',
    view: 'personal',
  });
  await store.put(leftover);
  const read = await readDutyScheduleEntry(store, current.key, NOW);
  assert.equal(read.userId, 'user-a');
  assert.deepEqual((await store.entries()).map((row) => row.userId), ['user-a']);
});

test('cached personal timing follows Vietnam clock and keeps edited timestamps', () => {
  const start = Date.UTC(2026, 8, 23, 8, 0, 0) - 7 * 60 * 60 * 1000;
  const event = {
    _id: 'duty-1',
    startDate: '2026-09-23',
    startTime: '08:00',
    endDate: '2026-09-23',
    endTime: '09:00',
    createdAt: 10,
    updatedAt: 40,
    canMarkSelectedUser: true,
    canMarkAttendance: false,
    timing: { isOngoing: false, isOverdue: false, isUpcoming: true, nearDeadline: false },
  };
  const before = refreshCachedDutyCalendar({ events: [event], revision: 'rev-1' }, start - 60_000);
  assert.equal(before.events[0].timing.isUpcoming, true);
  assert.equal(before.events[0].canMarkAttendance, false);
  assert.equal(before.events[0].createdAt, 10);
  assert.equal(before.events[0].updatedAt, 40);
  const during = refreshCachedDutyCalendar({ events: [event] }, start + 30 * 60_000);
  assert.equal(during.events[0].timing.isOngoing, true);
  assert.equal(during.events[0].canMarkAttendance, true);
  assert.equal(during.events[0].updatedAt, 40);
  const after = refreshCachedDutyCalendar({ events: [event] }, start + 2 * 60 * 60 * 1000);
  assert.equal(after.events[0].timing.isOverdue, true);
  assert.equal(after.events[0].canMarkAttendance, false);
  const soon = dutyEventTiming(event, start - 60 * 60 * 1000);
  assert.equal(soon.nearDeadline, true);
  assert.equal(soon.isUpcoming, true);
});

test('schedule views keep the narrow queries and add a browser stamp cache', () => {
  const sharedRevision = dutiesSource.slice(
    dutiesSource.indexOf('export const sharedScheduleRevision'),
    dutiesSource.indexOf('export const create'),
  );
  assert.match(sharedRevision, /loadSharedScheduleSlice/);
  assert.match(sharedRevision, /sharedScheduleStamp\(slice, user, access, isAdmin\)/);
  const slice = dutiesSource.slice(
    dutiesSource.indexOf('async function loadSharedScheduleSlice'),
    dutiesSource.indexOf('function sharedScheduleStamp'),
  );
  assert.match(slice, /loadActiveDutiesOverlapping/);
  assert.match(slice, /loadPublicDutiesOverlapping/);
  assert.doesNotMatch(slice, /\.collect\(\)/);
  assert.match(dutiesSource, /function sharedScheduleStamp/);
  assert.doesNotMatch(sharedRevision, /loadDocsByIds/);
  assert.doesNotMatch(sharedRevision, /loadScheduleSubordinates/);
  assert.doesNotMatch(sharedRevision, /\.collect\(\)/);

  const personalRevision = reportsSource.slice(
    reportsSource.indexOf('export const dutyCalendarRevision'),
    reportsSource.indexOf('export const workCalendar'),
  );
  assert.match(personalRevision, /loadCalendarDuties/);
  assert.match(personalRevision, /loadAttendancesForDuties/);
  assert.match(personalRevision, /buildDutyCalendarRevision/);
  assert.doesNotMatch(personalRevision, /loadActiveUsers/);
  assert.doesNotMatch(personalRevision, /query\("users"\)/);
  assert.doesNotMatch(personalRevision, /query\("duties"\)\.collect\(\)/);
  assert.doesNotMatch(personalRevision, /query\("dutyAttendances"\)\.collect\(\)/);

  assert.match(reportsSource, /canMarkSelectedUser,/);
  assert.match(reportsSource, /createdAt: duty\.createdAt/);
  assert.match(reportsSource, /updatedAt: duty\.updatedAt/);
  assert.match(dutiesSource, /updatedAt: duty\.updatedAt/);

  assert.match(sharedView, /useCachedDutySchedule/);
  assert.match(sharedView, /duties\.sharedScheduleRevision/);
  assert.match(sharedView, /duties\.sharedSchedule/);
  assert.match(sharedView, /Đang dựng lịch công tác chung…/);
  assert.match(personalView, /useCachedDutySchedule/);
  assert.match(personalView, /reports\.dutyCalendarRevision/);
  assert.match(personalView, /reports\.dutyCalendar/);
  assert.match(personalView, /Đang dựng lịch công tác…/);
  assert.match(hookSource, /useQuery/);
  assert.match(hookSource, /subscribeRevision \? queryArgs : 'skip'/);
  assert.match(hookSource, /subscribeLive \? queryArgs : 'skip'/);
  assert.match(hookSource, /liveHold/);
  assert.doesNotMatch(hookSource, /setInterval/);
  assert.doesNotMatch(cacheSource, /cloudflare|Mac Mini|minutely/i);
});
