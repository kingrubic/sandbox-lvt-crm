import React, { useMemo, useState } from 'react';
import { useQuery } from 'convex/react';
import { anyApi } from 'convex/server';
import { vietnamTodayYmd } from './homeroomTime';
import { sortClassesNatural } from './classOrder';
import { foldSearch, formatDate, formatDateTime, percent, schoolDayLabel } from './homeroomLabels';
import { AttendanceBar, DateStepper, EmptyState, Icon, Kpi, Loading, Notice } from './homeroomUi';

export default function HomeroomOverview({ yearId, roles, nav }) {
  const today = vietnamTodayYmd();
  const [date, setDate] = useState(today);
  if (roles.isSupervisor) return <SupervisorOverview yearId={yearId} date={date} setDate={setDate} today={today} nav={nav} />;
  return <ClassesOverview yearId={yearId} date={date} setDate={setDate} today={today} roles={roles} nav={nav} />;
}

function DayStrip({ date, setDate, today, schoolDay, max }) {
  return (
    <div className="hr-day-strip">
      <DateStepper value={date} onChange={setDate} max={max} />
      {schoolDay ? (
        <span className={`hr-day-badge ${schoolDay.isSchoolDay ? 'is-school' : 'is-off'}`}>
          <Icon name={schoolDay.isSchoolDay ? 'check' : 'calendar'} size={14} />
          {schoolDayLabel(schoolDay)}
          {schoolDay.note ? <em>· {schoolDay.note}</em> : null}
        </span>
      ) : null}
      {date !== today ? (
        <button type="button" className="hr-button hr-button--ghost" onClick={() => setDate(today)}>
          Về hôm nay
        </button>
      ) : null}
    </div>
  );
}

function ClassesOverview({ yearId, date, setDate, today, roles, nav }) {
  const overview = useQuery(anyApi.homeroomReports.overview, { schoolYearId: yearId, date });
  const [filter, setFilter] = useState('all');
  const [search, setSearch] = useState('');

  const classes = useMemo(() => sortClassesNatural(overview?.classes), [overview?.classes]);
  const visible = useMemo(() => {
    const needle = foldSearch(search);
    return classes.filter((row) => {
      if (filter === 'missing' && row.published) return false;
      if (filter === 'pending' && !row.pendingTotal) return false;
      if (!needle) return true;
      return foldSearch(`${row.code} ${row.name} ${row.teacherName}`).includes(needle);
    });
  }, [classes, filter, search]);

  if (overview === undefined) {
    return (
      <div className="hr-stack">
        <DayStrip date={date} setDate={setDate} today={today} schoolDay={null} max={today} />
        <Loading label="Đang tải tổng quan…" />
      </div>
    );
  }

  const counts = overview.summary.counts;
  const absentToday = counts.absent_pending + counts.absent_excused + counts.absent_unexcused;
  const publishedCount = classes.filter((row) => row.published).length;
  const schoolMode = overview.mode === 'school';

  return (
    <div className="hr-stack">
      <DayStrip date={date} setDate={setDate} today={today} schoolDay={overview.schoolDay} max={today} />

      {overview.schoolDay.outsideYear ? (
        <Notice tone="info" icon="calendar" title="Ngày đã chọn nằm ngoài năm học.">
          Năm học {overview.schoolYear.name}: {formatDate(overview.schoolYear.startDate)} – {formatDate(overview.schoolYear.endDate)}.
        </Notice>
      ) : !overview.schoolDay.isSchoolDay ? (
        <Notice tone="info" icon="calendar" title={`${schoolDayLabel(overview.schoolDay)} — không cần điểm danh.`}>
          {overview.schoolDay.note || 'Nếu hôm nay có dạy bù, quản trị viên đánh dấu “Ngày học bù” trong Lịch học.'}
        </Notice>
      ) : overview.missingUpload.shouldAlert ? (
        <Notice
          tone="danger"
          icon="clock"
          title={`Đã quá ${overview.missingUpload.cutoffTime} nhưng ${overview.missingUpload.missingClasses.length} lớp chưa có dữ liệu điểm danh.`}
          action={
            overview.permissions.canImport ? (
              <button type="button" className="primary-button" onClick={() => nav.import(date)}>
                <Icon name="upload" size={15} /> Nhập điểm danh
              </button>
            ) : null
          }
        >
          {overview.missingUpload.missingClasses.slice(0, 12).map((row) => row.code).join(', ')}
          {overview.missingUpload.missingClasses.length > 12 ? '…' : ''}
          {!overview.permissions.canImport ? ' — Giám thị sẽ nhập file điểm danh của trường.' : ''}
        </Notice>
      ) : null}

      <div className="hr-kpi-grid">
        <Kpi label={schoolMode ? 'Học sinh toàn trường' : 'Sĩ số lớp'} value={overview.studentCount} icon="users" hint={`${classes.length} lớp`} />
        <Kpi label="Có mặt" value={counts.present} tone="present" />
        <Kpi label="Đi trễ" value={counts.late} tone="late" />
        <Kpi label="Vắng" value={absentToday} tone="absent" hint={`${counts.absent_excused} có phép · ${counts.absent_unexcused} không phép`} />
        <Kpi
          label="Vắng chờ xử lý"
          value={overview.pendingTotal}
          tone="pending"
          icon="inbox"
          hint="Tất cả các ngày — bấm để xử lý"
          onClick={nav.pending}
        />
        <Kpi
          label="Chuyên cần"
          value={overview.summary.ratedRows ? percent(overview.summary.attendanceRate) : '—'}
          tone="rate"
          hint={schoolMode ? `${publishedCount}/${classes.length} lớp đã có dữ liệu` : 'Có mặt + trễ / tổng buổi'}
        />
      </div>

      {schoolMode ? (
        <section className="hr-panel">
          <header className="hr-panel-head">
            <div>
              <h2>Bảng điểm danh toàn trường</h2>
              <p className="hr-muted">Bấm vào một lớp để xem chi tiết ngày {formatDate(date)}.</p>
            </div>
            <div className="hr-row hr-row--wrap">
              <div className="hr-segment" role="group" aria-label="Lọc lớp">
                {[
                  ['all', `Tất cả (${classes.length})`],
                  ['missing', `Chưa có dữ liệu (${classes.length - publishedCount})`],
                  ['pending', `Còn vắng chờ xử lý (${classes.filter((row) => row.pendingTotal).length})`],
                ].map(([key, label]) => (
                  <button key={key} type="button" aria-pressed={filter === key} onClick={() => setFilter(key)}>
                    {label}
                  </button>
                ))}
              </div>
              <label className="hr-search">
                <Icon name="search" size={15} />
                <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Tìm lớp, GVCN…" aria-label="Tìm lớp" />
              </label>
            </div>
          </header>
          {!classes.length ? (
            <EmptyState icon="classes" title="Chưa có lớp đang hoạt động trong năm học này.">
              {roles.isManager ? 'Tạo lớp và phân công GVCN trong mục Quản lý lớp.' : null}
            </EmptyState>
          ) : !visible.length ? (
            <EmptyState icon="search" title="Không có lớp phù hợp bộ lọc." />
          ) : (
            <SchoolBoard classes={visible} onOpen={(id) => nav.openClass(id, 'diem-danh', date)} />
          )}
        </section>
      ) : (
        <section className="hr-stack">
          <h2 className="hr-section-title">Lớp đang chủ nhiệm</h2>
          {!classes.length ? (
            <div className="hr-panel">
              <EmptyState icon="classes" title="Bạn chưa được phân công chủ nhiệm lớp nào vào ngày này.">
                Khi quản trị viên phân công, lớp sẽ hiện ở đây cùng tình hình điểm danh hằng ngày.
              </EmptyState>
            </div>
          ) : (
            <ul className="hr-class-cards">
              {classes.map((row) => (
                <TeacherClassCard key={row._id} row={row} date={date} nav={nav} />
              ))}
            </ul>
          )}
        </section>
      )}
    </div>
  );
}

function SchoolBoard({ classes, onOpen }) {
  const grades = [...new Set(classes.map((row) => row.gradeLevel))].sort((a, b) => a - b);
  return (
    <div className="hr-table-wrap">
      <table className="hr-table hr-board">
        <thead>
          <tr>
            <th scope="col">Lớp</th>
            <th scope="col">GVCN</th>
            <th scope="col" className="is-num">Sĩ số</th>
            <th scope="col" className="hr-board-bar-col">Tình hình</th>
            <th scope="col" className="is-num">Có mặt</th>
            <th scope="col" className="is-num">Trễ</th>
            <th scope="col" className="is-num">Vắng</th>
            <th scope="col" className="is-num">Chờ xử lý</th>
          </tr>
        </thead>
        {grades.map((grade) => {
          const rows = classes.filter((row) => row.gradeLevel === grade);
          return (
            <tbody key={grade}>
              <tr className="hr-board-group">
                <th colSpan={8} scope="rowgroup">Khối {grade} · {rows.length} lớp</th>
              </tr>
              {rows.map((row) => {
                const absent = row.counts.absent_pending + row.counts.absent_excused + row.counts.absent_unexcused;
                return (
                  <tr key={row._id} className="is-clickable" onClick={() => onOpen(row._id)}>
                    <th scope="row">
                      <button type="button" className="hr-link" onClick={(event) => { event.stopPropagation(); onOpen(row._id); }}>
                        {row.code}
                      </button>
                      {row.name !== row.code ? <span className="hr-sub">{row.name}</span> : null}
                    </th>
                    <td>{row.teacherName || <span className="hr-muted">Chưa phân công</span>}</td>
                    <td className="is-num">{row.rosterCount}</td>
                    <td className="hr-board-bar-col">
                      {row.published ? (
                        <AttendanceBar counts={row.counts} total={row.rosterCount} compact />
                      ) : (
                        <span className="hr-tag hr-tag--muted">Chưa có dữ liệu</span>
                      )}
                    </td>
                    <td className="is-num">{row.published ? row.counts.present : '—'}</td>
                    <td className="is-num">{row.published ? row.counts.late : '—'}</td>
                    <td className="is-num">{row.published ? absent : '—'}</td>
                    <td className="is-num">
                      {row.pendingTotal ? <span className="hr-count hr-count--pending">{row.pendingTotal}</span> : <span className="hr-muted">0</span>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          );
        })}
      </table>
    </div>
  );
}

function TeacherClassCard({ row, date, nav }) {
  const absent = row.counts.absent_pending + row.counts.absent_excused + row.counts.absent_unexcused;
  return (
    <li className="hr-class-card">
      <div className="hr-class-card-head">
        <span className="hr-class-code">{row.code}</span>
        <div>
          <strong>{row.name}</strong>
          <span className="hr-sub">Khối {row.gradeLevel} · Sĩ số {row.rosterCount}</span>
        </div>
      </div>
      {row.published ? (
        <>
          <AttendanceBar counts={row.counts} total={row.rosterCount} />
          <dl className="hr-mini-stats">
            <div><dt>Có mặt</dt><dd>{row.counts.present}</dd></div>
            <div><dt>Trễ</dt><dd>{row.counts.late}</dd></div>
            <div><dt>Vắng</dt><dd>{absent}</dd></div>
          </dl>
        </>
      ) : (
        <p className="hr-class-card-empty"><Icon name="clock" size={15} /> Chưa có dữ liệu điểm danh ngày {formatDate(date)}.</p>
      )}
      <div className="hr-class-card-actions">
        {row.pendingTotal ? (
          <button type="button" className="hr-button hr-button--pending" onClick={() => nav.openClass(row._id, 'diem-danh', date)}>
            <Icon name="inbox" size={15} /> {row.pendingTotal} buổi vắng chờ xử lý
          </button>
        ) : (
          <span className="hr-tag hr-tag--ok"><Icon name="check" size={13} /> Không còn vắng chờ xử lý</span>
        )}
        <button type="button" className="primary-button" onClick={() => nav.openClass(row._id)}>
          Mở lớp <Icon name="arrowRight" size={15} />
        </button>
      </div>
    </li>
  );
}

function SupervisorOverview({ yearId, date, setDate, today, nav }) {
  const status = useQuery(anyApi.attendanceImport.uploadsForDate, { schoolYearId: yearId, attendanceDate: date });
  return (
    <div className="hr-stack">
      <DayStrip date={date} setDate={setDate} today={today} schoolDay={null} max={today} />
      <section className="hr-panel hr-hero-card">
        <div>
          <span className="hr-eyebrow">Giám thị</span>
          <h2>Nhập file điểm danh toàn trường</h2>
          <p className="hr-muted">
            Mỗi ngày nhập <strong>một file</strong> cho cả trường theo mẫu cố định. Hệ thống tự tách theo Mã lớp, cho xem trước từng lớp rồi mới công bố.
            Giáo viên chủ nhiệm sẽ tự phân loại vắng có phép / không phép.
          </p>
        </div>
        <button type="button" className="primary-button hr-button--lg" onClick={() => nav.import(date)}>
          <Icon name="upload" size={17} /> Nhập điểm danh ngày {formatDate(date)}
        </button>
      </section>
      <section className="hr-panel">
        <header className="hr-panel-head">
          <h2>Tình trạng ngày {formatDate(date)}</h2>
        </header>
        {status === undefined ? (
          <Loading />
        ) : !status.uploads.length ? (
          <EmptyState icon="file" title="Chưa công bố file nào cho ngày này." />
        ) : (
          <>
            <p className="hr-lead">
              Đã có dữ liệu cho <strong>{status.publishedClassCount}</strong> lớp.
            </p>
            <ul className="hr-upload-list">
              {status.uploads.map((row) => (
                <li key={row._id}>
                  <Icon name="file" size={16} />
                  <div>
                    <strong>{row.fileName}</strong>
                    <span className="hr-sub">
                      {row.matchedCount}/{row.rowCount} dòng khớp · {row.uploadedByName || 'Không rõ người nhập'} · {formatDateTime(row.publishedAt)}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          </>
        )}
      </section>
    </div>
  );
}
