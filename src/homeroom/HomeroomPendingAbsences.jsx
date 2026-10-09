import React, { useMemo, useState } from 'react';
import { useQuery } from 'convex/react';
import { anyApi } from 'convex/server';
import { foldSearch, formatDate, isYmd, weekdayLabel } from './homeroomLabels';
import { compareClasses } from './classOrder';
import { ClassifyAbsenceModal, DISPOSITION_BATCH_LIMIT } from './HomeroomDisposition';
import { EmptyState, Feedback, Icon, Loading, Notice } from './homeroomUi';

export default function HomeroomPendingAbsences({ yearId, nav }) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [classId, setClassId] = useState('');
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState(() => new Set());
  const [modal, setModal] = useState(null);
  const [success, setSuccess] = useState('');

  const rangeValid = (!from || isYmd(from)) && (!to || isYmd(to)) && (!from || !to || from <= to);
  const data = useQuery(
    anyApi.homeroomReports.pendingAbsences,
    rangeValid ? { schoolYearId: yearId, from: from || undefined, to: to || undefined } : 'skip',
  );

  const rows = data?.rows || [];
  const classOptions = useMemo(() => {
    const map = new Map();
    for (const row of rows) {
      if (!map.has(row.classId)) {
        map.set(row.classId, { classId: row.classId, code: row.classCode, name: row.className, gradeLevel: row.gradeLevel });
      }
    }
    return [...map.values()]
      .sort(compareClasses)
      .map((item) => [item.classId, item.code || item.name]);
  }, [rows]);

  const visible = useMemo(() => {
    const needle = foldSearch(search);
    return rows.filter((row) => {
      if (classId && row.classId !== classId) return false;
      if (!needle) return true;
      return foldSearch(`${row.fullName} ${row.studentCode} ${row.classCode}`).includes(needle);
    });
  }, [rows, classId, search]);

  const groups = useMemo(() => {
    const map = new Map();
    for (const row of visible) {
      const list = map.get(row.attendanceDate) || [];
      list.push(row);
      map.set(row.attendanceDate, list);
    }
    return [...map.entries()];
  }, [visible]);

  const correctable = visible.filter((row) => row.canCorrect);
  const selectedRows = visible.filter((row) => selected.has(row._id));
  const anyCorrectable = rows.some((row) => row.canCorrect);

  const toggle = (id) => {
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else if (next.size < DISPOSITION_BATCH_LIMIT) next.add(id);
      return next;
    });
  };

  const toggleGroup = (list) => {
    const ids = list.filter((row) => row.canCorrect).map((row) => row._id);
    const allOn = ids.every((id) => selected.has(id));
    setSelected((current) => {
      const next = new Set(current);
      for (const id of ids) {
        if (allOn) next.delete(id);
        else if (next.size < DISPOSITION_BATCH_LIMIT) next.add(id);
      }
      return next;
    });
  };

  const onDone = (count) => (choice) => {
    setSelected(new Set());
    setSuccess(`Đã phân loại ${count} buổi là ${choice === 'excused' ? 'vắng có phép' : 'vắng không phép'}.`);
  };

  return (
    <div className="hr-stack">
      <section className="hr-panel">
        <header className="hr-panel-head">
          <div>
            <h2>Vắng chờ xử lý</h2>
            <p className="hr-muted">
              Các buổi camera ghi <strong>Vắng</strong> nhưng chưa phân loại. Giáo viên chủ nhiệm xác nhận có phép / không phép cho lớp mình.
            </p>
          </div>
          {data ? <span className="hr-big-count" aria-label="Tổng số buổi">{data.total}</span> : null}
        </header>
        <div className="hr-filter-bar">
          <label className="hr-field hr-field--inline">
            <span>Lớp</span>
            <select value={classId} onChange={(e) => setClassId(e.target.value)}>
              <option value="">Tất cả lớp</option>
              {classOptions.map(([id, label]) => (
                <option key={id} value={id}>{label}</option>
              ))}
            </select>
          </label>
          <label className="hr-field hr-field--inline">
            <span>Từ ngày</span>
            <input type="date" value={from} max={to || undefined} onChange={(e) => setFrom(e.target.value)} />
          </label>
          <label className="hr-field hr-field--inline">
            <span>Đến ngày</span>
            <input type="date" value={to} min={from || undefined} onChange={(e) => setTo(e.target.value)} />
          </label>
          <label className="hr-search">
            <Icon name="search" size={15} />
            <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Tìm học sinh…" aria-label="Tìm học sinh" />
          </label>
          {from || to || classId || search ? (
            <button type="button" className="hr-button hr-button--ghost" onClick={() => { setFrom(''); setTo(''); setClassId(''); setSearch(''); }}>
              Xóa lọc
            </button>
          ) : null}
        </div>
        {!rangeValid ? <Feedback error="Khoảng ngày không hợp lệ: “Từ ngày” phải trước hoặc bằng “Đến ngày”." /> : null}
        <Feedback success={success} />
        {data && !anyCorrectable && rows.length ? (
          <Notice tone="info" icon="eye" title="Chế độ chỉ xem.">
            Chỉ giáo viên chủ nhiệm của lớp (hoặc quản trị viên) mới phân loại được buổi vắng.
          </Notice>
        ) : null}
        {data?.truncated ? (
          <Notice tone="warn" icon="alert" title={`Đang hiển thị 500/${data.total} buổi mới nhất.`}>
            Dùng bộ lọc ngày để xem các buổi cũ hơn.
          </Notice>
        ) : null}
      </section>

      {data === undefined && rangeValid ? (
        <Loading label="Đang tải danh sách vắng…" />
      ) : !visible.length ? (
        <div className="hr-panel">
          <EmptyState icon="check" title={rows.length ? 'Không có buổi vắng khớp bộ lọc.' : 'Tuyệt vời — không còn buổi vắng nào chờ xử lý.'} />
        </div>
      ) : (
        <div className="hr-stack">
          {groups.map(([date, list]) => {
            const groupIds = list.filter((row) => row.canCorrect).map((row) => row._id);
            const groupChecked = groupIds.length > 0 && groupIds.every((id) => selected.has(id));
            return (
              <section key={date} className="hr-panel hr-inbox-group">
                <header className="hr-inbox-head">
                  {groupIds.length ? (
                    <label className="hr-check">
                      <input type="checkbox" checked={groupChecked} onChange={() => toggleGroup(list)} aria-label={`Chọn tất cả ngày ${formatDate(date)}`} />
                    </label>
                  ) : null}
                  <h3>{weekdayLabel(date)}, {formatDate(date)}</h3>
                  <span className="hr-count hr-count--pending">{list.length}</span>
                </header>
                <ul className="hr-inbox-list">
                  {list.map((row) => (
                    <li key={row._id} className={selected.has(row._id) ? 'is-selected' : ''}>
                      {row.canCorrect ? (
                        <label className="hr-check">
                          <input type="checkbox" checked={selected.has(row._id)} onChange={() => toggle(row._id)} aria-label={`Chọn ${row.fullName}`} />
                        </label>
                      ) : <span className="hr-check-spacer" />}
                      <div className="hr-inbox-who">
                        <button type="button" className="hr-link" onClick={() => nav.openStudent(row.studentId)}>{row.fullName}</button>
                        <span className="hr-sub">{row.studentCode} · Lớp {row.classCode}{row.note ? ` · ${row.note}` : ''}</span>
                      </div>
                      {row.canCorrect ? (
                        <div className="hr-inbox-actions">
                          <button type="button" className="hr-button hr-button--excused" onClick={() => setModal({ rows: [row], choice: 'excused' })}>
                            Có phép
                          </button>
                          <button type="button" className="hr-button hr-button--unexcused" onClick={() => setModal({ rows: [row], choice: 'unexcused' })}>
                            Không phép
                          </button>
                        </div>
                      ) : (
                        <button type="button" className="hr-button hr-button--ghost" onClick={() => nav.openClass(row.classId, 'diem-danh', row.attendanceDate)}>
                          Xem lớp
                        </button>
                      )}
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
        </div>
      )}

      {selectedRows.length ? (
        <div className="hr-bulk-bar" role="region" aria-label="Thao tác hàng loạt">
          <strong>Đã chọn {selectedRows.length}{selected.size >= DISPOSITION_BATCH_LIMIT ? ` (tối đa ${DISPOSITION_BATCH_LIMIT})` : ''}</strong>
          <button type="button" className="hr-button hr-button--excused" onClick={() => setModal({ rows: selectedRows, choice: 'excused' })}>
            Có phép
          </button>
          <button type="button" className="hr-button hr-button--unexcused" onClick={() => setModal({ rows: selectedRows, choice: 'unexcused' })}>
            Không phép
          </button>
          <button type="button" className="hr-button hr-button--ghost" onClick={() => setSelected(new Set())}>Bỏ chọn</button>
        </div>
      ) : correctable.length > 1 ? (
        <p className="hr-hint">Mẹo: tick nhiều học sinh để phân loại cùng lúc (tối đa {DISPOSITION_BATCH_LIMIT} buổi).</p>
      ) : null}

      {modal ? (
        <ClassifyAbsenceModal
          rows={modal.rows}
          initialChoice={modal.choice}
          onClose={() => setModal(null)}
          onDone={onDone(modal.rows.length)}
        />
      ) : null}
    </div>
  );
}
