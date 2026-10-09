import React, { useRef, useState } from 'react';
import { useAction, useMutation, useQuery } from 'convex/react';
import { anyApi } from 'convex/server';
import { downloadAttendanceImportTemplate } from '../lib/attendanceImportExcel';
import { messageFor } from '../lib/appErrorMessage';
import { vietnamTodayYmd } from './homeroomTime';
import { formatDate, formatDateLong, formatDateTime, importColumnLabel, schoolDayLabel } from './homeroomLabels';
import {
  ATTENDANCE_IMPORT_MAX_BYTES,
  attendanceReplaceModeChoices,
  buildAttendancePublishArgs,
  buildAttendanceValidateArgs,
  classPreviewState,
  isAttendanceReplaceModeRequired,
  publishPlan,
  REPLACE_MODE_CANCEL,
} from './attendanceImportPreview';
import { DateStepper, EmptyState, Feedback, Icon, Kpi, Notice } from './homeroomUi';

const STEPS = ['Chọn ngày & file', 'Kiểm tra từng lớp', 'Công bố'];

export default function HomeroomAttendanceImport({ yearId, initialDate = '', nav }) {
  const today = vietnamTodayYmd();
  const [date, setDate] = useState(() => (initialDate && initialDate <= today ? initialDate : today));
  const [preview, setPreview] = useState(null);
  const [result, setResult] = useState(null);
  const [replaceMode, setReplaceMode] = useState('');
  const [phase, setPhase] = useState('');
  const [error, setError] = useState('');
  const [issueFilter, setIssueFilter] = useState('');

  const generateUploadUrl = useMutation(anyApi.attendanceImport.generateUploadUrl);
  const registerUpload = useMutation(anyApi.attendanceImport.registerUpload);
  const validateUpload = useAction(anyApi.attendanceImport.validate);
  const publishUpload = useMutation(anyApi.attendanceImport.publish);

  const step = result ? 2 : preview ? 1 : 0;
  const busy = Boolean(phase);

  const reset = () => {
    setPreview(null);
    setResult(null);
    setReplaceMode('');
    setError('');
    setIssueFilter('');
  };

  const onFile = async (file) => {
    if (!file) return;
    reset();
    if (!file.name.toLowerCase().endsWith('.xlsx')) {
      setError('Chỉ nhận file Excel .xlsx theo mẫu điểm danh toàn trường.');
      return;
    }
    if (file.size > ATTENDANCE_IMPORT_MAX_BYTES) {
      setError('File vượt quá 4 MB. Hãy xóa các cột/sheet thừa rồi thử lại.');
      return;
    }
    try {
      setPhase('Đang tải file lên…');
      const uploadUrl = await generateUploadUrl({ schoolYearId: yearId, attendanceDate: date });
      const uploaded = await fetch(uploadUrl, {
        method: 'POST',
        headers: { 'Content-Type': file.type || 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' },
        body: file,
      });
      if (!uploaded.ok) throw new Error('IMPORT_UPLOAD_NOT_FOUND');
      const { storageId } = await uploaded.json();
      const { uploadId } = await registerUpload({
        storageId,
        fileName: file.name,
        fileSize: file.size,
        schoolYearId: yearId,
        attendanceDate: date,
      });
      setPhase('Đang đọc và đối soát với danh sách lớp…');
      setPreview(await validateUpload(buildAttendanceValidateArgs({ uploadId })));
    } catch (err) {
      setError(messageFor(err));
    } finally {
      setPhase('');
    }
  };

  const plan = publishPlan(preview, replaceMode);

  const publish = async () => {
    setError('');
    if (plan.needsReplaceMode && !replaceMode) {
      setError('Có lớp đã có dữ liệu ngày này — hãy chọn cách xử lý bên dưới.');
      return;
    }
    setPhase('Đang công bố…');
    try {
      const published = await publishUpload(buildAttendancePublishArgs({ uploadId: preview.uploadId, replaceMode }));
      setResult({ ...published, attendanceDate: preview.attendanceDate, missingStudents: plan.missingStudents });
    } catch (err) {
      if (isAttendanceReplaceModeRequired(err)) {
        setError('Một số lớp vừa có dữ liệu mới cho ngày này — hãy chọn cách xử lý rồi công bố lại.');
      } else {
        setError(messageFor(err));
      }
    } finally {
      setPhase('');
    }
  };

  return (
    <div className="hr-stack">
      <section className="hr-panel">
        <header className="hr-panel-head">
          <div>
            <h2>Nhập điểm danh</h2>
            <p className="hr-muted">Một file Excel cho cả trường mỗi ngày. Hệ thống tự tách theo Lớp học và nhận diện học sinh bằng Họ tên + Ngày sinh; lớp có lỗi được bỏ qua, các lớp đúng vẫn công bố.</p>
          </div>
          <button type="button" className="hr-button" onClick={() => downloadAttendanceImportTemplate()}>
            <Icon name="download" size={15} /> Tải file mẫu
          </button>
        </header>
        <ol className="hr-stepper" aria-label="Các bước">
          {STEPS.map((label, index) => (
            <li key={label} className={index < step ? 'is-done' : index === step ? 'is-current' : ''} aria-current={index === step ? 'step' : undefined}>
              <span className="hr-stepper-dot">{index < step ? <Icon name="check" size={13} strokeWidth={2.4} /> : index + 1}</span>
              {label}
            </li>
          ))}
        </ol>
      </section>

      {step === 0 ? (
        <UploadStep yearId={yearId} date={date} setDate={setDate} today={today} busy={busy} phase={phase} error={error} onFile={onFile} />
      ) : step === 1 ? (
        <PreviewStep
          preview={preview}
          plan={plan}
          busy={busy}
          phase={phase}
          error={error}
          replaceMode={replaceMode}
          setReplaceMode={setReplaceMode}
          issueFilter={issueFilter}
          setIssueFilter={setIssueFilter}
          onPublish={publish}
          onRestart={reset}
        />
      ) : (
        <section className="hr-panel hr-done-panel" role="status">
          <span className="hr-done-icon"><Icon name="check" size={30} strokeWidth={2.2} /></span>
          <h2>Đã công bố điểm danh {formatDate(result.attendanceDate)}</h2>
          <p className="hr-lead">
            {result.idempotent
              ? 'File này đã được công bố trước đó — không có thay đổi mới.'
              : `${result.classCount} lớp · ${result.count} bản ghi được ghi/cập nhật.`}
          </p>
          {result.skippedClassCodes?.length ? (
            <p className="hr-muted">Bỏ qua (đã có dữ liệu): {result.skippedClassCodes.join(', ')}.</p>
          ) : null}
          {result.missingStudents ? (
            <p className="hr-muted">{result.missingStudents} học sinh không có trong file đã được ghi “Vắng chờ xử lý” để GVCN phân loại.</p>
          ) : null}
          <div className="hr-row hr-row--center">
            <button type="button" className="hr-button" onClick={reset}>
              <Icon name="upload" size={15} /> Nhập file khác
            </button>
            <button type="button" className="primary-button" onClick={nav.overview}>
              Về tổng quan <Icon name="arrowRight" size={15} />
            </button>
          </div>
        </section>
      )}
    </div>
  );
}

function UploadStep({ yearId, date, setDate, today, busy, phase, error, onFile }) {
  const inputRef = useRef(null);
  const [dragging, setDragging] = useState(false);
  const status = useQuery(anyApi.attendanceImport.uploadsForDate, { schoolYearId: yearId, attendanceDate: date });
  return (
    <section className="hr-panel">
      <div className="hr-upload-grid">
        <div className="hr-stack hr-stack--tight">
          <span className="hr-field-label">Ngày điểm danh</span>
          <DateStepper value={date} onChange={setDate} max={today} />
          {status ? (
            status.publishedClassCount ? (
              <Notice tone="warn" icon="alert" title={`Ngày ${formatDate(date)} đã có dữ liệu ở ${status.publishedClassCount} lớp.`}>
                Nếu nhập tiếp, bạn sẽ được chọn bổ sung, ghi đè, hoặc bỏ qua các lớp đó.
                {status.uploads[0] ? ` File gần nhất: ${status.uploads[0].fileName} (${formatDateTime(status.uploads[0].publishedAt)}).` : ''}
              </Notice>
            ) : (
              <p className="hr-hint"><Icon name="check" size={13} /> Ngày {formatDate(date)} chưa có dữ liệu điểm danh.</p>
            )
          ) : null}
          <ul className="hr-checklist">
            <li>Cột: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh, Thời gian điểm danh.</li>
            <li>Học sinh khớp theo Lớp + Họ tên + Ngày sinh (dd/mm/yyyy).</li>
            <li>Trạng thái: Đúng giờ / Đi trễ / Chưa điểm danh.</li>
            <li>“Chưa điểm danh” hoặc thiếu trong file → “Vắng chờ xử lý”.</li>
          </ul>
        </div>
        <div
          className={`hr-dropzone${dragging ? ' is-dragging' : ''}${busy ? ' is-busy' : ''}`}
          onDragOver={(event) => {
            event.preventDefault();
            setDragging(true);
          }}
          onDragLeave={() => setDragging(false)}
          onDrop={(event) => {
            event.preventDefault();
            setDragging(false);
            if (!busy) onFile(event.dataTransfer.files?.[0]);
          }}
        >
          <Icon name={busy ? 'clock' : 'upload'} size={34} strokeWidth={1.5} />
          {busy ? (
            <>
              <strong>{phase}</strong>
              <span className="hr-loading-bar" aria-hidden="true" />
            </>
          ) : (
            <>
              <strong>Kéo thả file .xlsx vào đây</strong>
              <span>hoặc</span>
              <button type="button" className="primary-button" onClick={() => inputRef.current?.click()}>
                Chọn file điểm danh
              </button>
              <small>Tối đa 4 MB · 3.000 dòng</small>
            </>
          )}
          <input
            ref={inputRef}
            type="file"
            accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            className="hr-sr-only"
            tabIndex={-1}
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              onFile(file);
            }}
          />
        </div>
      </div>
      <Feedback error={error} />
    </section>
  );
}

function PreviewStep({
  preview,
  plan,
  busy,
  phase,
  error,
  replaceMode,
  setReplaceMode,
  issueFilter,
  setIssueFilter,
  onPublish,
  onRestart,
}) {
  const issues = (preview.issues || []).filter((item) => !issueFilter || item.severity === issueFilter);

  return (
    <>
      <section className="hr-panel">
        <header className="hr-panel-head">
          <div>
            <h2>{preview.fileName}</h2>
            <p className="hr-muted">
              Ngày điểm danh: <strong>{formatDateLong(preview.attendanceDate)}</strong>
              {preview.schoolDay ? ` · ${schoolDayLabel(preview.schoolDay)}` : ''}
            </p>
          </div>
          <button type="button" className="hr-button hr-button--ghost" onClick={onRestart} disabled={busy}>
            <Icon name="restore" size={15} /> Chọn file khác
          </button>
        </header>
        {preview.schoolDay && !preview.schoolDay.isSchoolDay ? (
          <Notice tone="warn" icon="calendar" title={`Ngày đã chọn là ${schoolDayLabel(preview.schoolDay).toLowerCase()}.`}>
            Kiểm tra lại ngày điểm danh. Nếu trường dạy bù, quản trị viên cần đánh dấu “Ngày học bù” trong Lịch học.
          </Notice>
        ) : null}
        <div className="hr-kpi-grid hr-kpi-grid--compact">
          <Kpi label="Dòng trong file" value={preview.totalRows} />
          <Kpi label="Khớp học sinh" value={preview.matchedCount} tone="present" />
          <Kpi label="Lỗi" value={preview.errorCount} tone={preview.errorCount ? 'absent' : 'neutral'} />
          <Kpi label="Cảnh báo" value={preview.warningCount} tone={preview.warningCount ? 'late' : 'neutral'} />
          <Kpi label="Lớp sẵn sàng" value={`${plan.publishable.length}/${preview.classes.length}`} tone="rate" />
        </div>
      </section>

      <section className="hr-panel">
        <header className="hr-panel-head">
          <h3>Từng lớp trong file</h3>
          {preview.classesWithoutRows?.length ? (
            <span className="hr-tag hr-tag--warn">{preview.classesWithoutRows.length} lớp không có dòng nào</span>
          ) : null}
        </header>
        {!preview.classes.length ? (
          <EmptyState icon="file" title="Không tìm thấy lớp hợp lệ nào trong file.">
            Kiểm tra cột “Lớp học” có trùng tên hoặc mã lớp trên phần mềm không (7/1 được hiểu là 7-1).
          </EmptyState>
        ) : (
          <div className="hr-table-wrap">
            <table className="hr-table">
              <thead>
                <tr>
                  <th>Lớp</th>
                  <th className="is-num">Sĩ số</th>
                  <th className="is-num">Có mặt</th>
                  <th className="is-num">Trễ</th>
                  <th className="is-num">Vắng</th>
                  <th className="is-num" title="Có trong danh sách lớp nhưng không có trong file">Thiếu trong file</th>
                  <th className="is-num">Lỗi</th>
                  <th>Trạng thái</th>
                </tr>
              </thead>
              <tbody>
                {preview.classes.map((row) => {
                  const state = classPreviewState(row);
                  return (
                    <tr key={row.classId}>
                      <th scope="row">{row.code}{row.name !== row.code ? <span className="hr-sub">{row.name}</span> : null}</th>
                      <td className="is-num">{row.rosterCount}</td>
                      <td className="is-num">{row.present}</td>
                      <td className="is-num">{row.late}</td>
                      <td className="is-num">{row.absent}</td>
                      <td className="is-num">{row.missingCount ? <span className="hr-count hr-count--pending">{row.missingCount}</span> : 0}</td>
                      <td className="is-num">{row.errorCount ? <span className="hr-count hr-count--error">{row.errorCount}</span> : 0}</td>
                      <td><span className={`hr-state hr-state--${state.key}`}>{state.label}</span></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        {preview.classesWithoutRows?.length ? (
          <p className="hr-hint">
            Không có trong file (sẽ không công bố): {preview.classesWithoutRows.map((row) => row.code).join(', ')}.
          </p>
        ) : null}
      </section>

      {preview.issues?.length ? (
        <section className="hr-panel">
          <header className="hr-panel-head">
            <h3>Dòng cần sửa ({preview.errorCount} lỗi · {preview.warningCount} cảnh báo)</h3>
            <div className="hr-segment" role="group" aria-label="Lọc vấn đề">
              {[['', 'Tất cả'], ['error', 'Lỗi'], ['warning', 'Cảnh báo']].map(([key, label]) => (
                <button key={key || 'all'} type="button" aria-pressed={issueFilter === key} onClick={() => setIssueFilter(key)}>{label}</button>
              ))}
            </div>
          </header>
          <div className="hr-table-wrap hr-table-wrap--scroll">
            <table className="hr-table">
              <thead>
                <tr><th className="is-num">Dòng</th><th>Cột</th><th>Giá trị</th><th>Vấn đề</th></tr>
              </thead>
              <tbody>
                {issues.map((item, index) => (
                  <tr key={`${item.rowNumber}-${item.code}-${index}`} className={item.severity === 'error' ? 'is-error' : 'is-warning'}>
                    <td className="is-num">{item.rowNumber || '—'}</td>
                    <td>{importColumnLabel(item.field)}</td>
                    <td>{item.rejectedValue ? <code>{item.rejectedValue}</code> : <span className="hr-muted">(trống)</span>}</td>
                    <td>{item.message}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {preview.issuesTruncated ? <p className="hr-hint">Chỉ hiển thị 400 vấn đề đầu tiên. Sửa file rồi tải lại để xem tiếp.</p> : null}
        </section>
      ) : null}

      <section className="hr-panel hr-publish-panel">
        {plan.needsReplaceMode ? (
          <fieldset className="hr-choice-group hr-choice-group--cards">
            <legend>{plan.conflicts.length} lớp đã có dữ liệu ngày này ({plan.conflicts.map((row) => row.code).join(', ')}). Xử lý thế nào?</legend>
            {attendanceReplaceModeChoices().map((choice) => (
              <label key={choice.replaceMode} className="hr-choice">
                <input
                  type="radio"
                  name="replaceMode"
                  value={choice.replaceMode}
                  checked={replaceMode === choice.replaceMode}
                  onChange={() => setReplaceMode(choice.replaceMode)}
                />
                <span>
                  <strong>{choice.label}</strong>
                  <small>{choice.description}</small>
                </span>
              </label>
            ))}
          </fieldset>
        ) : null}
        <div className="hr-publish-row">
          <div>
            {plan.willPublish.length ? (
              <>
                <strong>Sẽ công bố {plan.willPublish.length} lớp</strong>
                <span className="hr-sub">
                  {plan.missingStudents ? `${plan.missingStudents} học sinh không có trong file sẽ ghi “Vắng chờ xử lý”. ` : ''}
                  {plan.skipped.length ? `Bỏ qua ${plan.skipped.length} lớp có lỗi.` : ''}
                </span>
              </>
            ) : (
              <strong>Chưa có lớp nào đủ điều kiện công bố.</strong>
            )}
          </div>
          <button
            type="button"
            className="primary-button hr-button--lg"
            onClick={onPublish}
            disabled={busy || !plan.willPublish.length || (plan.needsReplaceMode && !replaceMode) || (replaceMode === REPLACE_MODE_CANCEL && !plan.willPublish.length)}
          >
            {busy ? phase : `Công bố ${plan.willPublish.length} lớp`}
          </button>
        </div>
        <Feedback error={error} />
      </section>
    </>
  );
}
