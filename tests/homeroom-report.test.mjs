import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  UNKNOWN_STUDENT_CODE,
  UNKNOWN_STUDENT_NAME,
  assertExportWithinScope,
  authorizeAttendanceSummaryRows,
  buildAttendanceExportPayload,
  enrichAttendanceSummaryRows,
  resolveScopedExportTitles,
  summarizeAttendanceDays,
} from '../convex/homeroomReportPolicy.ts';
import { HOMEROOM_SCOPE_FORBIDDEN } from '../convex/homeroomPolicy.ts';

const days = [
  { classId: 'c1', studentId: 's1', attendanceDate: '2026-09-01', effectiveStatus: 'present', rawObservation: 'present' },
  { classId: 'c1', studentId: 's2', attendanceDate: '2026-09-01', effectiveStatus: 'late', rawObservation: 'late' },
  { classId: 'c1', studentId: 's3', attendanceDate: '2026-09-01', effectiveStatus: 'absent_excused', rawObservation: 'absent' },
  { classId: 'c1', studentId: 's4', attendanceDate: '2026-09-01', effectiveStatus: 'exempt', rawObservation: 'unknown' },
  { classId: 'c1', studentId: 's5', attendanceDate: '2026-09-01', effectiveStatus: 'no_data', rawObservation: 'unknown' },
  { classId: 'c2', studentId: 's9', attendanceDate: '2026-09-01', effectiveStatus: 'absent_pending', rawObservation: 'absent' },
];

test('weekly and monthly totals reconcile to daily rows and exclude exempt/no_data from the rate', () => {
  const summary = summarizeAttendanceDays(days, { classIds: ['c1'], from: '2026-09-01', to: '2026-09-07' });
  assert.equal(summary.counts.present, 1);
  assert.equal(summary.counts.late, 1);
  assert.equal(summary.counts.absent_excused, 1);
  assert.equal(summary.counts.exempt, 1);
  assert.equal(summary.counts.no_data, 1);
  assert.equal(summary.ratedRows, 3);
  assert.equal(summary.attendanceRate, 2 / 3);
  assert.equal(summary.days.length, 5);
});

test('export cannot exceed actor scope and remains drillable to source days', () => {
  assert.throws(() => assertExportWithinScope(['c2'], { kind: 'ids', classIds: ['c1'] }), /HOMEROOM_SCOPE_FORBIDDEN/);
  const scoped = assertExportWithinScope(['c1'], { kind: 'ids', classIds: ['c1'] });
  assert.deepEqual(scoped, ['c1']);
  assert.deepEqual(assertExportWithinScope(undefined, { kind: 'none' }), []);
  assert.throws(() => assertExportWithinScope(['c1'], { kind: 'none' }), /HOMEROOM_SCOPE_FORBIDDEN/);
  assert.deepEqual(assertExportWithinScope(undefined, { kind: 'all' }), []);
  assert.deepEqual(assertExportWithinScope(['c2'], { kind: 'all' }), ['c2']);
  const payload = buildAttendanceExportPayload({
    summary: summarizeAttendanceDays(days, { classIds: ['c1'], from: '2026-09-01', to: '2026-09-01' }),
    className: '6A1',
    schoolYearName: '2026-2027',
    from: '2026-09-01',
    to: '2026-09-01',
    generatedAt: 1,
    generatedByUserId: 'u1',
    generatedByName: 'Giám thị',
  });
  assert.equal(payload.rows.every((row) => row.classId === 'c1'), true);
  assert.ok(payload.rows[0].attendanceDate);
  assert.equal(payload.title.includes('điểm danh'), true);
});

const teacher = {
  userId: 'teacher-1',
  role: 'user',
  status: 'active',
  menuAccess: { homeroom: 'view' },
};

const viewAll = {
  userId: 'viewer-1',
  role: 'user',
  status: 'active',
  menuAccess: { homeroom: 'view_all' },
};

const admin = {
  userId: 'admin-1',
  role: 'admin',
  status: 'active',
  menuAccess: {},
};

const augustOnlyAssignment = {
  classId: 'c1',
  schoolYearId: 'year-1',
  userId: 'teacher-1',
  assignmentType: 'homeroom_teacher',
  scopeKind: 'class',
  effectiveFrom: '2026-08-01',
  effectiveTo: '2026-08-31',
  active: true,
};

const rangeDays = [
  { classId: 'c1', studentId: 's1', attendanceDate: '2026-08-20', effectiveStatus: 'present' },
  { classId: 'c1', studentId: 's1', attendanceDate: '2026-09-01', effectiveStatus: 'absent_pending' },
  { classId: 'c2', studentId: 's9', attendanceDate: '2026-08-20', effectiveStatus: 'present' },
];

test('attendance summary authorizes every row by class and attendanceDate, not only range.from', () => {
  const authorized = authorizeAttendanceSummaryRows({
    actor: teacher,
    assignments: [augustOnlyAssignment],
    days: rangeDays,
    classId: 'c1',
    from: '2026-08-01',
    to: '2026-09-30',
    schoolYearId: 'year-1',
  });
  assert.deepEqual(authorized.map((row) => row.attendanceDate), ['2026-08-20']);

  const noClassFilter = authorizeAttendanceSummaryRows({
    actor: teacher,
    assignments: [augustOnlyAssignment],
    days: rangeDays,
    from: '2026-08-01',
    to: '2026-09-30',
    schoolYearId: 'year-1',
  });
  assert.deepEqual(noClassFilter.map((row) => `${row.classId}:${row.attendanceDate}`), ['c1:2026-08-20']);

  assert.throws(
    () =>
      authorizeAttendanceSummaryRows({
        actor: teacher,
        assignments: [{ ...augustOnlyAssignment, active: false }],
        days: rangeDays,
        classId: 'c1',
        from: '2026-08-01',
        to: '2026-09-30',
        schoolYearId: 'year-1',
      }),
    new RegExp(HOMEROOM_SCOPE_FORBIDDEN),
  );
  assert.throws(
    () =>
      authorizeAttendanceSummaryRows({
        actor: teacher,
        assignments: [],
        days: rangeDays,
        from: '2026-08-01',
        to: '2026-09-30',
        schoolYearId: 'year-1',
      }),
    new RegExp(HOMEROOM_SCOPE_FORBIDDEN),
  );
  assert.throws(
    () =>
      authorizeAttendanceSummaryRows({
        actor: teacher,
        assignments: [augustOnlyAssignment],
        days: rangeDays,
        classId: 'c2',
        from: '2026-08-01',
        to: '2026-09-30',
        schoolYearId: 'year-1',
      }),
    new RegExp(HOMEROOM_SCOPE_FORBIDDEN),
  );

  const managerRows = authorizeAttendanceSummaryRows({
    actor: admin,
    assignments: [],
    days: rangeDays,
    from: '2026-08-01',
    to: '2026-09-30',
  });
  assert.equal(managerRows.length, 3);
  const viewAllRows = authorizeAttendanceSummaryRows({
    actor: viewAll,
    assignments: [],
    days: rangeDays,
    classId: 'c1',
    from: '2026-08-01',
    to: '2026-09-30',
  });
  assert.deepEqual(viewAllRows.map((row) => row.attendanceDate), ['2026-08-20', '2026-09-01']);

  const supervisor = {
    userId: 'sup-1',
    role: 'user',
    status: 'active',
    menuAccess: { homeroom: 'supervisor' },
  };
  const wholeSchool = {
    classId: '',
    schoolYearId: 'year-1',
    userId: 'sup-1',
    assignmentType: 'supervisor',
    scopeKind: 'whole_school',
    effectiveFrom: '2026-08-01',
    active: true,
  };
  assert.throws(
    () =>
      authorizeAttendanceSummaryRows({
        actor: supervisor,
        assignments: [wholeSchool],
        days: rangeDays,
        from: '2026-08-01',
        to: '2026-09-30',
        schoolYearId: 'year-1',
      }),
    new RegExp(HOMEROOM_SCOPE_FORBIDDEN),
  );
  assert.throws(
    () =>
      authorizeAttendanceSummaryRows({
        actor: supervisor,
        assignments: [{ ...wholeSchool, classId: 'c1', scopeKind: 'class' }],
        days: rangeDays,
        classId: 'c1',
        from: '2026-08-01',
        to: '2026-09-30',
        schoolYearId: 'year-1',
      }),
    new RegExp(HOMEROOM_SCOPE_FORBIDDEN),
  );

  const source = readFileSync(new URL('../convex/homeroomReports.ts', import.meta.url), 'utf8');
  assert.match(source, /authorizeAttendanceSummaryRows/);
  assert.doesNotMatch(source, /assertClassReadable/);
  assert.doesNotMatch(source, /evaluateMissingUploadAlert\(/);
  assert.match(source, /evaluateScopedMissingUploadAlerts/);
  assert.match(source, /resolveOverviewScope/);
});

const INTERNAL_STUDENT_ID = 'qn7abcinternalstudent01';
const OTHER_STUDENT_ID = 'qn9leakotherstudent02';

const uatAuthorizedDays = [
  {
    classId: 'class-6a1',
    studentId: INTERNAL_STUDENT_ID,
    attendanceDate: '2026-09-01',
    effectiveStatus: 'present',
    rawObservation: 'present',
  },
  {
    classId: 'class-6a1',
    studentId: INTERNAL_STUDENT_ID,
    attendanceDate: '2026-09-02',
    effectiveStatus: 'absent_unexcused',
    rawObservation: 'absent',
  },
];

test('attendance summary enriches scoped rows with public student identity after authorize', () => {
  const students = [
    {
      _id: INTERNAL_STUDENT_ID,
      studentCode: 'QA-HS001',
      fullName: 'Nguyễn An',
      status: 'active',
      studentPhone: '0909000001',
      guardianName: 'Không được lộ',
    },
    {
      _id: OTHER_STUDENT_ID,
      studentCode: 'QA-HS999',
      fullName: 'Học sinh lớp khác',
      status: 'active',
      studentPhone: '0909000999',
    },
    {
      _id: 'qn8deactivatedstudent03',
      studentCode: 'QA-HS008',
      fullName: 'Học sinh nghỉ',
      status: 'inactive',
    },
  ];

  const enriched = enrichAttendanceSummaryRows(uatAuthorizedDays, students);
  assert.equal(enriched.length, 2);
  assert.equal(enriched[0].studentCode, 'QA-HS001');
  assert.equal(enriched[0].fullName, 'Nguyễn An');
  assert.equal(enriched[0].studentId, INTERNAL_STUDENT_ID);
  assert.equal(enriched[0].studentPhone, undefined);
  assert.equal(enriched[0].guardianName, undefined);
  assert.equal(enriched.some((row) => row.studentCode === 'QA-HS999'), false);

  const missing = enrichAttendanceSummaryRows(
    [{ ...uatAuthorizedDays[0], studentId: 'qn7missingstudent99' }],
    students,
  );
  assert.equal(missing[0].studentCode, UNKNOWN_STUDENT_CODE);
  assert.equal(missing[0].fullName, UNKNOWN_STUDENT_NAME);
  assert.equal(missing[0].studentId, 'qn7missingstudent99');

  const deactivated = enrichAttendanceSummaryRows(
    [{ ...uatAuthorizedDays[0], studentId: 'qn8deactivatedstudent03' }],
    students,
  );
  assert.equal(deactivated[0].studentCode, UNKNOWN_STUDENT_CODE);
  assert.equal(deactivated[0].fullName, UNKNOWN_STUDENT_NAME);
  assert.equal(deactivated[0].studentId, 'qn8deactivatedstudent03');

  const source = readFileSync(new URL('../convex/homeroomReports.ts', import.meta.url), 'utf8');
  const authorizeAt = source.indexOf('authorizeAttendanceSummaryRows');
  const enrichAt = source.indexOf('enrichAttendanceSummaryRows');
  assert.ok(authorizeAt >= 0 && enrichAt > authorizeAt);
  assert.match(source, /resolveScopedExportTitles/);
  assert.doesNotMatch(source, /studentGuardians|studentPhone|guardian/);
});

test('export payload keeps UAT rate and shows class/year titles from scoped records only', () => {
  const enriched = enrichAttendanceSummaryRows(uatAuthorizedDays, [
    { _id: INTERNAL_STUDENT_ID, studentCode: 'QA-HS001', fullName: 'Nguyễn An', status: 'active' },
  ]);
  const summary = summarizeAttendanceDays(enriched, {
    classIds: ['class-6a1'],
    from: '2026-09-01',
    to: '2026-09-02',
  });
  assert.equal(summary.totalRows, 2);
  assert.equal(summary.ratedRows, 2);
  assert.equal(summary.attendanceRate, 0.5);
  assert.equal((summary.attendanceRate * 100).toFixed(1), '50.0');

  const titles = resolveScopedExportTitles({
    classId: 'class-6a1',
    schoolYearId: 'year-1',
    scopedClassIds: ['class-6a1'],
    classes: [
      { _id: 'class-6a1', name: '6A1', code: '6A1', schoolYearId: 'year-1' },
      { _id: 'class-leak', name: 'Lớp ngoài phạm vi', code: '9Z9', schoolYearId: 'year-leak' },
    ],
    schoolYears: [
      { _id: 'year-1', name: '2026-2027' },
      { _id: 'year-leak', name: 'Năm học rò rỉ' },
    ],
  });
  assert.equal(titles.className, '6A1');
  assert.equal(titles.schoolYearName, '2026-2027');

  const payload = buildAttendanceExportPayload({
    summary,
    className: titles.className,
    schoolYearName: titles.schoolYearName,
    from: '2026-09-01',
    to: '2026-09-02',
    generatedAt: 1,
    generatedByUserId: 'u1',
    generatedByName: 'Giám thị',
  });
  assert.equal(payload.className, '6A1');
  assert.equal(payload.schoolYearName, '2026-2027');
  assert.equal(payload.attendanceRate, 0.5);
  assert.equal(payload.rows.length, 2);
  assert.equal(payload.rows[0].studentCode, 'QA-HS001');
  assert.equal(payload.rows[0].fullName, 'Nguyễn An');
  assert.equal(payload.rows[0].studentId, INTERNAL_STUDENT_ID);
  assert.equal(payload.rows[1].effectiveStatus, 'absent_unexcused');
});
