import React, { useState } from 'react';
import { useMutation } from 'convex/react';
import { anyApi } from 'convex/server';
import { formatDate, REASON_PRESETS, statusLabel } from './homeroomLabels';
import { Feedback, Icon, Modal, useAsyncTask } from './homeroomUi';

export const DISPOSITION_BATCH_LIMIT = 100;

const CHOICES = [
  { key: 'excused', label: 'Vắng có phép', tone: 'excused', hint: 'Có xin phép / lý do chính đáng' },
  { key: 'unexcused', label: 'Vắng không phép', tone: 'unexcused', hint: 'Không xin phép hoặc lý do không hợp lệ' },
];

/**
 * Hộp phân loại vắng cho 1 hoặc nhiều buổi (camera ghi "Vắng").
 * rows: [{ _id, fullName, studentCode, attendanceDate, classCode? , disposition? }]
 */
export function ClassifyAbsenceModal({ rows, initialChoice = 'excused', onClose, onDone = undefined }) {
  const setDisposition = useMutation(anyApi.studentAttendance.setDisposition);
  const setDispositionMany = useMutation(anyApi.studentAttendance.setDispositionMany);
  const single = rows.length === 1 ? rows[0] : null;
  const alreadyClassified = Boolean(single && single.disposition && single.disposition !== 'pending' && single.disposition !== 'none');
  const [choice, setChoice] = useState(initialChoice);
  const [preset, setPreset] = useState(single?.reasonCode || '');
  const [note, setNote] = useState(single?.note || '');
  const task = useAsyncTask();

  const presets = choice === 'pending' ? [] : REASON_PRESETS[choice] || [];
  const needsReason = choice !== 'pending' && !preset && !note.trim();

  const submit = async (event) => {
    event.preventDefault();
    if (needsReason) {
      task.setError('Chọn một lý do gợi ý hoặc nhập ghi chú.');
      return;
    }
    const payload = {
      nextDisposition: choice,
      reasonCode: choice === 'pending' ? undefined : preset || undefined,
      note: note.trim() || undefined,
    };
    const outcome = await task.run(async () => {
      if (single) return await setDisposition({ attendanceDayId: single._id, ...payload });
      return await setDispositionMany({ attendanceDayIds: rows.map((row) => row._id), ...payload });
    });
    if (outcome.ok) {
      onDone?.(choice);
      onClose();
    }
  };

  return (
    <Modal
      title={single ? 'Phân loại buổi vắng' : `Phân loại ${rows.length} buổi vắng`}
      subtitle={
        single
          ? `${single.fullName} · ${single.studentCode}${single.classCode ? ` · ${single.classCode}` : ''} · ${formatDate(single.attendanceDate)}`
          : 'Cùng một lý do sẽ áp dụng cho tất cả buổi đã chọn.'
      }
      onClose={onClose}
      busy={task.pending}
      footer={
        <>
          <button type="button" className="hr-button hr-button--ghost" onClick={onClose} disabled={task.pending}>Hủy</button>
          <button type="submit" form="hr-classify-form" className="primary-button" disabled={task.pending}>
            {task.pending ? 'Đang lưu…' : 'Lưu phân loại'}
          </button>
        </>
      }
    >
      <form id="hr-classify-form" className="hr-form" onSubmit={submit}>
        {!single ? (
          <ul className="hr-chip-list" aria-label="Buổi vắng đã chọn">
            {rows.slice(0, 8).map((row) => (
              <li key={row._id}>{row.fullName} · {formatDate(row.attendanceDate)}</li>
            ))}
            {rows.length > 8 ? <li>+{rows.length - 8} buổi khác</li> : null}
          </ul>
        ) : null}
        <fieldset className="hr-choice-group">
          <legend>Kết quả</legend>
          {CHOICES.map((item) => (
            <label key={item.key} className={`hr-choice hr-choice--${item.tone}`}>
              <input
                type="radio"
                name="disposition"
                value={item.key}
                checked={choice === item.key}
                onChange={() => {
                  setChoice(item.key);
                  if (preset && !(REASON_PRESETS[item.key] || []).includes(preset)) setPreset('');
                }}
              />
              <span>
                <strong>{item.label}</strong>
                <small>{item.hint}</small>
              </span>
            </label>
          ))}
          {alreadyClassified ? (
            <label className="hr-choice hr-choice--pending">
              <input type="radio" name="disposition" value="pending" checked={choice === 'pending'} onChange={() => setChoice('pending')} />
              <span>
                <strong>Đưa về chờ xử lý</strong>
                <small>Hiện đang là “{statusLabel(single.effectiveStatus)}”</small>
              </span>
            </label>
          ) : null}
        </fieldset>
        {presets.length ? (
          <div className="hr-field">
            <span>Lý do</span>
            <div className="hr-preset-row">
              {presets.map((item) => (
                <button
                  key={item}
                  type="button"
                  className="hr-preset"
                  aria-pressed={preset === item}
                  onClick={() => setPreset(preset === item ? '' : item)}
                >
                  {item}
                </button>
              ))}
            </div>
          </div>
        ) : null}
        <label className="hr-field">
          <span>Ghi chú {choice !== 'pending' && !preset ? '(bắt buộc nếu không chọn lý do)' : '(không bắt buộc)'}</span>
          <textarea rows={3} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Ví dụ: Mẹ em gọi điện lúc 7:10 báo em sốt." />
        </label>
        <p className="hr-hint"><Icon name="clock" size={13} /> Mọi thay đổi đều được lưu lịch sử (ai sửa, lúc nào, lý do).</p>
        <Feedback error={task.error} />
      </form>
    </Modal>
  );
}
