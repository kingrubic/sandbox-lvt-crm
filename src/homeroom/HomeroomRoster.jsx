import React, { useMemo, useRef, useState } from 'react';
import { useAction, useMutation, useQuery } from 'convex/react';
import { anyApi } from 'convex/server';
import { downloadRosterImportTemplate } from '../lib/rosterImportExcel';
import { messageFor } from '../lib/appErrorMessage';
import { vietnamTodayYmd } from './homeroomTime';
import { sortClassesNatural } from './classOrder';
import { foldSearch, formatDate, GENDER_OPTIONS, genderLabel, relationshipLabel, studentInitials } from './homeroomLabels';
import { EmptyState, Feedback, Icon, Loading, Modal, Notice, useAsyncTask } from './homeroomUi';

export default function HomeroomRoster({ classId, detail, nav }) {
  const roster = useQuery(anyApi.students.listByClass, { classId });
  const [search, setSearch] = useState('');
  const [modal, setModal] = useState(null);
  const canManage = Boolean(detail.permissions?.canManage) && detail.class.status !== 'archived';

  const rows = roster?.rows || [];
  const visible = useMemo(() => {
    const needle = foldSearch(search);
    if (!needle) return rows;
    return rows.filter((row) => foldSearch(`${row.student.fullName} ${row.student.studentCode}`).includes(needle));
  }, [rows, search]);

  return (
    <div className="hr-stack">
      <div className="hr-toolbar">
        <label className="hr-search hr-search--wide">
          <Icon name="search" size={15} />
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Tìm theo tên hoặc mã học sinh…" aria-label="Tìm học sinh" />
        </label>
        {canManage ? (
          <div className="hr-row hr-row--wrap">
            <button type="button" className="hr-button" onClick={() => setModal({ kind: 'import' })}>
              <Icon name="upload" size={15} /> Nhập danh sách Excel
            </button>
            <button type="button" className="primary-button" onClick={() => setModal({ kind: 'create' })}>
              <Icon name="plus" size={15} /> Thêm học sinh
            </button>
          </div>
        ) : null}
      </div>

      {roster === undefined ? (
        <Loading label="Đang tải danh sách lớp…" />
      ) : !rows.length ? (
        <EmptyState icon="users" title="Lớp chưa có học sinh.">
          {canManage ? 'Thêm từng học sinh hoặc nhập cả danh sách bằng file Excel mẫu.' : 'Quản trị viên sẽ cập nhật danh sách lớp.'}
        </EmptyState>
      ) : (
        <div className="hr-table-wrap">
          <table className="hr-table hr-roster">
            <thead>
              <tr>
                <th className="is-num">STT</th>
                <th>Học sinh</th>
                <th>Ngày sinh</th>
                <th>Giới tính</th>
                {roster.showContacts ? <th>Liên hệ</th> : null}
                <th className="is-actions"><span className="hr-sr-only">Thao tác</span></th>
              </tr>
            </thead>
            <tbody>
              {visible.map((row, index) => {
                const primary = row.guardians.find((item) => item.isPrimaryContact) || row.guardians[0];
                return (
                  <tr key={row.enrollment._id}>
                    <td className="is-num">{row.enrollment.rosterNumber || index + 1}</td>
                    <td>
                      <button type="button" className="hr-person" onClick={() => nav.openStudent(row.student._id)}>
                        <span className="hr-avatar" aria-hidden="true">{studentInitials(row.student.fullName)}</span>
                        <span>
                          <strong>{row.student.fullName}</strong>
                          <span className="hr-sub">{row.student.studentCode}</span>
                        </span>
                      </button>
                    </td>
                    <td>{row.student.dateOfBirth ? formatDate(row.student.dateOfBirth) : '—'}</td>
                    <td>{genderLabel(row.student.gender)}</td>
                    {roster.showContacts ? (
                      <td>
                        {primary ? (
                          <span className="hr-contact">
                            <span>{relationshipLabel(primary.relationship)}: {primary.fullName}</span>
                            {primary.phone ? <a href={`tel:${primary.phone}`} className="hr-sub"><Icon name="phone" size={12} /> {primary.phone}</a> : null}
                          </span>
                        ) : (
                          <span className="hr-muted">Chưa có</span>
                        )}
                      </td>
                    ) : null}
                    <td className="is-actions">
                      <div className="hr-row hr-row--end">
                        <button type="button" className="hr-button hr-button--ghost hr-button--sm" onClick={() => nav.openStudent(row.student._id)}>
                          Chi tiết
                        </button>
                        {canManage ? (
                          <>
                            <button type="button" className="hr-icon-button" title="Chuyển lớp" aria-label={`Chuyển lớp ${row.student.fullName}`} onClick={() => setModal({ kind: 'transfer', row })}>
                              <Icon name="transfer" size={16} />
                            </button>
                            <button type="button" className="hr-icon-button hr-icon-button--danger" title="Cho nghỉ học" aria-label={`Cho nghỉ học ${row.student.fullName}`} onClick={() => setModal({ kind: 'withdraw', row })}>
                              <Icon name="leave" size={16} />
                            </button>
                          </>
                        ) : null}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {!visible.length ? <EmptyState icon="search" title="Không tìm thấy học sinh phù hợp." /> : null}
        </div>
      )}
      {roster && !roster.showContacts && rows.length ? (
        <p className="hr-hint"><Icon name="eye" size={13} /> Thông tin liên hệ phụ huynh chỉ hiển thị cho GVCN của lớp và quản trị viên.</p>
      ) : null}

      {modal?.kind === 'create' ? <CreateStudentModal classId={classId} detail={detail} onClose={() => setModal(null)} /> : null}
      {modal?.kind === 'import' ? <RosterImportModal classId={classId} detail={detail} onClose={() => setModal(null)} /> : null}
      {modal?.kind === 'transfer' ? <TransferModal row={modal.row} detail={detail} onClose={() => setModal(null)} /> : null}
      {modal?.kind === 'withdraw' ? <WithdrawModal row={modal.row} onClose={() => setModal(null)} /> : null}
    </div>
  );
}

function CreateStudentModal({ classId, detail, onClose }) {
  const create = useMutation(anyApi.students.create);
  const today = vietnamTodayYmd();
  const [form, setForm] = useState({
    studentCode: '',
    fullName: '',
    dateOfBirth: '',
    gender: '',
    rosterNumber: '',
    startDate: today,
  });
  const task = useAsyncTask();
  const set = (key) => (event) => setForm((current) => ({ ...current, [key]: event.target.value }));

  return (
    <Modal
      title="Thêm học sinh"
      subtitle={`Vào lớp ${detail.class.code} — ${detail.class.name}`}
      onClose={onClose}
      busy={task.pending}
      footer={
        <>
          <button type="button" className="hr-button hr-button--ghost" onClick={onClose} disabled={task.pending}>Hủy</button>
          <button type="submit" form="hr-create-student" className="primary-button" disabled={task.pending}>
            {task.pending ? 'Đang lưu…' : 'Thêm học sinh'}
          </button>
        </>
      }
    >
      <form
        id="hr-create-student"
        className="hr-form hr-form-grid"
        onSubmit={async (event) => {
          event.preventDefault();
          const outcome = await task.run(() =>
            create({
              classId,
              studentCode: form.studentCode,
              fullName: form.fullName,
              dateOfBirth: form.dateOfBirth || undefined,
              gender: form.gender || undefined,
              rosterNumber: form.rosterNumber ? Number(form.rosterNumber) : undefined,
              startDate: form.startDate,
            }),
          );
          if (outcome.ok) onClose();
        }}
      >
        <label className="hr-field">
          <span>Mã học sinh *</span>
          <input value={form.studentCode} onChange={set('studentCode')} required maxLength={30} autoComplete="off" spellCheck={false} />
        </label>
        <label className="hr-field">
          <span>Họ và tên *</span>
          <input value={form.fullName} onChange={set('fullName')} required maxLength={120} autoComplete="off" />
        </label>
        <label className="hr-field">
          <span>Ngày sinh</span>
          <input type="date" value={form.dateOfBirth} onChange={set('dateOfBirth')} max={today} />
        </label>
        <label className="hr-field">
          <span>Giới tính</span>
          <select value={form.gender} onChange={set('gender')}>
            <option value="">Chưa chọn</option>
            {GENDER_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </label>
        <label className="hr-field">
          <span>Số thứ tự</span>
          <input type="number" min={1} max={200} value={form.rosterNumber} onChange={set('rosterNumber')} />
        </label>
        <label className="hr-field">
          <span>Vào lớp từ ngày *</span>
          <input type="date" value={form.startDate} onChange={set('startDate')} required />
        </label>
        <div className="hr-form-span">
          <Feedback error={task.error} />
        </div>
      </form>
    </Modal>
  );
}

function TransferModal({ row, detail, onClose }) {
  const classes = useQuery(anyApi.homeroomClasses.listCatalog, { schoolYearId: detail.class.schoolYearId });
  const transfer = useMutation(anyApi.homeroomClasses.transferStudent);
  const [toClassId, setToClassId] = useState('');
  const [date, setDate] = useState(vietnamTodayYmd());
  const [reason, setReason] = useState('');
  const task = useAsyncTask();
  const targets = sortClassesNatural(classes).filter((item) => item.status === 'active' && item._id !== detail.class._id);

  return (
    <Modal
      title="Chuyển lớp"
      subtitle={`${row.student.fullName} · ${row.student.studentCode} · đang học ${detail.class.code}`}
      onClose={onClose}
      busy={task.pending}
      footer={
        <>
          <button type="button" className="hr-button hr-button--ghost" onClick={onClose} disabled={task.pending}>Hủy</button>
          <button type="submit" form="hr-transfer" className="primary-button" disabled={task.pending || !toClassId}>
            {task.pending ? 'Đang chuyển…' : 'Chuyển lớp'}
          </button>
        </>
      }
    >
      <form
        id="hr-transfer"
        className="hr-form"
        onSubmit={async (event) => {
          event.preventDefault();
          const outcome = await task.run(() =>
            transfer({ enrollmentId: row.enrollment._id, toClassId, date, reason: reason.trim() || undefined }),
          );
          if (outcome.ok) onClose();
        }}
      >
        <label className="hr-field">
          <span>Lớp mới *</span>
          <select value={toClassId} onChange={(e) => setToClassId(e.target.value)} required>
            <option value="">{classes === undefined ? 'Đang tải lớp…' : 'Chọn lớp'}</option>
            {targets.map((item) => (
              <option key={item._id} value={item._id}>{item.code} — {item.name}</option>
            ))}
          </select>
        </label>
        <label className="hr-field">
          <span>Học lớp mới từ ngày *</span>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
        </label>
        <label className="hr-field">
          <span>Lý do</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="Ví dụ: Theo nguyện vọng phụ huynh" />
        </label>
        <p className="hr-hint">Lịch sử điểm danh ở lớp cũ được giữ nguyên. Số thứ tự ở lớp mới sẽ để trống.</p>
        <Feedback error={task.error} />
      </form>
    </Modal>
  );
}

function WithdrawModal({ row, onClose }) {
  const withdraw = useMutation(anyApi.homeroomClasses.withdrawStudent);
  const [date, setDate] = useState(vietnamTodayYmd());
  const [reason, setReason] = useState('');
  const task = useAsyncTask();
  return (
    <Modal
      title="Cho học sinh nghỉ học"
      subtitle={`${row.student.fullName} · ${row.student.studentCode}`}
      onClose={onClose}
      busy={task.pending}
      footer={
        <>
          <button type="button" className="hr-button hr-button--ghost" onClick={onClose} disabled={task.pending}>Hủy</button>
          <button type="submit" form="hr-withdraw" className="primary-button hr-button--danger" disabled={task.pending}>
            {task.pending ? 'Đang lưu…' : 'Xác nhận nghỉ học'}
          </button>
        </>
      }
    >
      <form
        id="hr-withdraw"
        className="hr-form"
        onSubmit={async (event) => {
          event.preventDefault();
          const outcome = await task.run(() => withdraw({ enrollmentId: row.enrollment._id, date, reason: reason.trim() || undefined }));
          if (outcome.ok) onClose();
        }}
      >
        <label className="hr-field">
          <span>Nghỉ từ ngày *</span>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
        </label>
        <label className="hr-field">
          <span>Lý do</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="Ví dụ: Chuyển trường" />
        </label>
        <Notice tone="warn" icon="alert" title="Từ ngày này học sinh không còn trong danh sách lớp.">
          Dữ liệu điểm danh trước đó vẫn được lưu trong hồ sơ học sinh.
        </Notice>
        <Feedback error={task.error} />
      </form>
    </Modal>
  );
}

function RosterImportModal({ classId, detail, onClose }) {
  const generate = useMutation(anyApi.studentRosterImport.generateUploadUrl);
  const register = useMutation(anyApi.studentRosterImport.registerUpload);
  const validateUpload = useAction(anyApi.studentRosterImport.validateUpload);
  const commitUpload = useAction(anyApi.studentRosterImport.commit);
  const [error, setError] = useState('');
  const [preview, setPreview] = useState(null);
  const [pending, setPending] = useState('');
  const [done, setDone] = useState(false);
  const uploadIdRef = useRef('');
  const inputRef = useRef(null);

  const onFile = async (file) => {
    setError('');
    setPreview(null);
    if (!file) return;
    if (!file.name.toLowerCase().endsWith('.xlsx')) {
      setError('Chỉ chấp nhận file Excel (.xlsx).');
      return;
    }
    setPending('Đang kiểm tra file…');
    try {
      const uploadUrl = await generate({ classId });
      const uploaded = await fetch(uploadUrl, { method: 'POST', headers: { 'Content-Type': file.type || 'application/octet-stream' }, body: file });
      const { storageId } = await uploaded.json();
      const registered = await register({
        storageId,
        fileName: file.name,
        fileSize: file.size,
        schoolYearId: detail.class.schoolYearId,
        classId,
      });
      uploadIdRef.current = registered.uploadId;
      setPreview(await validateUpload({ uploadId: registered.uploadId }));
    } catch (err) {
      setError(messageFor(err));
    } finally {
      setPending('');
    }
  };

  const commit = async () => {
    setPending('Đang nhập danh sách…');
    setError('');
    try {
      await commitUpload({ uploadId: uploadIdRef.current });
      setDone(true);
    } catch (err) {
      setError(messageFor(err));
    } finally {
      setPending('');
    }
  };

  const blockers = preview?.blockers || [];
  const warnings = (preview?.issues || []).filter((item) => item.severity === 'warning');

  return (
    <Modal
      title="Nhập danh sách học sinh"
      subtitle={`Lớp ${detail.class.code} — ${detail.class.name}`}
      onClose={onClose}
      busy={Boolean(pending)}
      size="lg"
      footer={
        done ? (
          <button type="button" className="primary-button" onClick={onClose}>Xong</button>
        ) : (
          <>
            <button type="button" className="hr-button hr-button--ghost" onClick={onClose} disabled={Boolean(pending)}>Đóng</button>
            {preview?.ok ? (
              <button type="button" className="primary-button" onClick={() => void commit()} disabled={Boolean(pending)}>
                {pending || `Xác nhận nhập ${preview.preview.length} học sinh`}
              </button>
            ) : null}
          </>
        )
      }
    >
      {done ? (
        <Notice tone="success" icon="check" title="Đã nhập danh sách học sinh.">Danh sách lớp đã được cập nhật.</Notice>
      ) : (
        <div className="hr-form">
          <div className="hr-row hr-row--wrap">
            <button type="button" className="hr-button" onClick={() => downloadRosterImportTemplate()}>
              <Icon name="download" size={15} /> Tải file mẫu
            </button>
            <button type="button" className="primary-button" onClick={() => inputRef.current?.click()} disabled={Boolean(pending)}>
              <Icon name="upload" size={15} /> Chọn file .xlsx
            </button>
            <input
              ref={inputRef}
              type="file"
              accept=".xlsx"
              className="hr-sr-only"
              tabIndex={-1}
              onChange={(event) => {
                const file = event.target.files?.[0];
                event.target.value = '';
                void onFile(file);
              }}
            />
          </div>
          {pending ? <p className="hr-hint"><Icon name="clock" size={13} /> {pending}</p> : null}
          <Feedback error={error} />
          {blockers.length ? (
            <>
              <Notice tone="danger" icon="alert" title={`File có ${blockers.length} lỗi — chưa nhập dòng nào.`}>
                Sửa các dòng dưới đây trong file rồi tải lại.
              </Notice>
              <div className="hr-table-wrap hr-table-wrap--scroll">
                <table className="hr-table">
                  <thead><tr><th className="is-num">Dòng</th><th>Cột</th><th>Giá trị</th><th>Vấn đề</th></tr></thead>
                  <tbody>
                    {blockers.map((item, index) => (
                      <tr key={`${item.rowNumber}-${item.code}-${index}`} className="is-error">
                        <td className="is-num">{item.rowNumber || '—'}</td>
                        <td>{item.column || '—'}</td>
                        <td>{item.rejectedValue ? <code>{item.rejectedValue}</code> : <span className="hr-muted">(trống)</span>}</td>
                        <td>{item.message}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}
          {warnings.length ? (
            <ul className="hr-issue-list">
              {warnings.map((item, index) => (
                <li key={`${item.rowNumber}-${index}`}>Dòng {item.rowNumber}: {item.message}</li>
              ))}
            </ul>
          ) : null}
          {preview?.ok ? (
            <Notice tone="success" icon="check" title={`File hợp lệ: ${preview.preview.length} học sinh sẵn sàng nhập.`} />
          ) : null}
        </div>
      )}
    </Modal>
  );
}
