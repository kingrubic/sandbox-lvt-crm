import React from 'react';

import { attendanceStatusLabel, formatAttendanceStudentLabel } from './homeroomExport.js';

function statusChip(status) {
  const key = status || 'no_data';
  return React.createElement(
    'span',
    { className: `hr-chip hr-chip--${key}` },
    React.createElement('span', { className: 'hr-chip-dot', 'aria-hidden': 'true' }),
    attendanceStatusLabel(key),
  );
}

export function AttendanceReportsTable({ days }) {
  return React.createElement(
    'table',
    { className: 'hr-table' },
    React.createElement(
      'thead',
      null,
      React.createElement(
        'tr',
        null,
        React.createElement('th', null, 'Ngày'),
        React.createElement('th', null, 'Học sinh'),
        React.createElement('th', null, 'Trạng thái'),
      ),
    ),
    React.createElement(
      'tbody',
      null,
      (days || []).map((row) =>
        React.createElement(
          'tr',
          { key: `${row.studentId}-${row.attendanceDate}` },
          React.createElement('td', null, row.attendanceDate),
          React.createElement('td', null, formatAttendanceStudentLabel(row)),
          React.createElement('td', null, statusChip(row.effectiveStatus)),
        ),
      ),
    ),
  );
}
