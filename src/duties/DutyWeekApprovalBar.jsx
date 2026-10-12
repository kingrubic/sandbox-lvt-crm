import { useId, useState } from 'react';
import { useMutation } from 'convex/react';
import { anyApi } from 'convex/server';
import ConfirmActionModal from '../lib/ConfirmActionModal';
import { messageFor } from '../lib/appErrorMessage';
import {
  DUTY_WEEK_RETURN_NOTE_MAX,
  dutyWeekChangeLabel,
  dutyWeekPill,
  formatWeekMoment,
  formatWeekRange,
} from './dutyWeekApproval.js';

function ChangeList({ changes }) {
  if (!changes?.length) return null;
  return (
    <ul className="lct-week-changes">
      {changes.map((change) => (
        <li key={`${change.kind}-${change.id}`}>
          <span className={`lct-week-change-kind is-${change.kind}`}>{dutyWeekChangeLabel(change.kind)}</span>
          {change.title || 'Công tác'}
        </li>
      ))}
    </ul>
  );
}

function ReturnDialog({ week, pending, onCancel, onConfirm }) {
  const titleId = useId();
  const [note, setNote] = useState('');
  const trimmed = note.trim();
  return (
    <div className="work-modal-backdrop duty-preview-backdrop" role="presentation" onClick={pending ? undefined : onCancel}>
      <section
        className="work-modal lct-week-return-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onClick={(event) => event.stopPropagation()}
      >
        <span className="work-kicker">TRẢ LẠI</span>
        <h3 id={titleId}>Trả lại lịch tuần {formatWeekRange(week.weekStart)}</h3>
        <label className="lct-week-return-field">
          <span>Lý do (văn thư sẽ thấy để sửa lại)</span>
          <textarea
            value={note}
            maxLength={DUTY_WEEK_RETURN_NOTE_MAX}
            rows={4}
            autoFocus
            onChange={(event) => setNote(event.target.value)}
            placeholder="Ví dụ: Thứ Tư đổi giờ dự giờ sang 9g00, bổ sung thành phần tổ Toán."
          />
        </label>
        <div className="work-modal-actions">
          <button type="button" className="work-ghost-button" onClick={onCancel} disabled={pending}>
            Hủy
          </button>
          <button
            type="button"
            className="work-primary-button lct-week-return-confirm"
            disabled={pending || !trimmed}
            onClick={() => onConfirm(trimmed)}
          >
            {pending ? 'Đang gửi…' : 'Trả lại'}
          </button>
        </div>
      </section>
    </div>
  );
}

function managerCopy(week) {
  const range = formatWeekRange(week.weekStart);
  const missing = week.missingParticipants
    ? `${week.missingParticipants} công tác chưa có thành phần.`
    : '';
  switch (week.status) {
    case 'draft':
      return {
        text: `Lịch tuần ${range} chưa nộp. Giáo viên chưa nhìn thấy lịch này.`,
        hint: ['Có thể nhập 4 cột trước, bổ sung Thành phần sau.', missing].filter(Boolean).join(' '),
      };
    case 'submitted':
      return {
        text: `Đã nộp ${formatWeekMoment(week.submittedAt)}. Đang chờ Ban Giám hiệu duyệt.`,
        hint: 'Nếu sửa lịch lúc này, bản đã nộp sẽ được rút lại và cần nộp lần nữa.',
      };
    case 'returned':
      return {
        text: `${week.returnedByName || 'Ban Giám hiệu'} trả lại ${formatWeekMoment(week.returnedAt)}: “${week.returnNote || ''}”`,
        hint: week.hasApprovedVersion
          ? 'Sửa xong bấm nộp lại. Giáo viên vẫn xem bản đã duyệt trước đó.'
          : 'Sửa xong bấm nộp lại. Giáo viên chưa nhìn thấy lịch tuần này.',
      };
    case 'approved':
      return {
        text: week.approvedAt
          ? `${week.approvedByName || 'Ban Giám hiệu'} duyệt ${formatWeekMoment(week.approvedAt)}.`
          : 'Lịch tuần này đã có hiệu lực.',
        hint: 'Giáo viên đang thấy lịch này. Sửa lịch sẽ cần Ban Giám hiệu duyệt lại.',
      };
    case 'approved_changed':
      return {
        text: `${week.changeCount} thay đổi so với bản đã duyệt. Giáo viên vẫn xem bản cũ cho tới khi Ban Giám hiệu duyệt lại.`,
        hint: missing,
      };
    default:
      return { text: `Tuần ${range} chưa có công tác.`, hint: '' };
  }
}

function reviewerCopy(week) {
  switch (week.status) {
    case 'submitted':
      return {
        text: `${week.submittedByName || 'Văn thư'} nộp ${formatWeekMoment(week.submittedAt)}.`,
        hint: `Duyệt một lần cho cả tuần ${formatWeekRange(week.weekStart)} (${week.changeCount} thay đổi).`,
      };
    case 'returned':
      return {
        text: `Đã trả lại ${formatWeekMoment(week.returnedAt)}: “${week.returnNote || ''}”`,
        hint: 'Văn thư đang sửa lại.',
      };
    case 'approved':
      return {
        text: week.approvedAt
          ? `${week.approvedByName || 'Ban Giám hiệu'} duyệt ${formatWeekMoment(week.approvedAt)}.`
          : 'Lịch tuần này đã có hiệu lực.',
        hint: '',
      };
    case 'approved_changed':
      return { text: 'Văn thư đang sửa lịch đã duyệt.', hint: 'Giáo viên vẫn xem bản cũ cho tới khi lịch được nộp và duyệt lại.' };
    case 'draft':
      return { text: 'Văn thư đang soạn lịch tuần này.', hint: 'Lịch sẽ hiện nút duyệt khi văn thư nộp.' };
    default:
      return { text: 'Tuần này chưa có công tác.', hint: '' };
  }
}

export default function DutyWeekApprovalBar({ week, canSubmit, canReview }) {
  const submit = useMutation(anyApi.dutyWeeks.submit);
  const approve = useMutation(anyApi.dutyWeeks.approve);
  const returnWeek = useMutation(anyApi.dutyWeeks.returnWeek);
  const discard = useMutation(anyApi.dutyWeeks.discardChanges);
  const [confirm, setConfirm] = useState(null);
  const [pending, setPending] = useState('');
  const [feedback, setFeedback] = useState({ type: '', text: '' });

  if (!week || (!canSubmit && !canReview)) return null;
  if (week.status === 'empty' && !canSubmit) return null;
  const pill = dutyWeekPill(week.status);
  const copy = canSubmit ? managerCopy(week) : reviewerCopy(week);
  const showChanges = week.changeCount > 0 && ['submitted', 'returned', 'approved_changed', 'draft'].includes(week.status);
  const canSend = canSubmit && week.changeCount > 0 && ['draft', 'returned', 'approved_changed'].includes(week.status);
  const canDiscard = canSubmit && week.hasApprovedVersion && week.changeCount > 0 && week.status !== 'submitted';
  const canDecide = canReview && week.status === 'submitted';

  const run = async (key, action, success) => {
    setPending(key);
    setFeedback({ type: '', text: '' });
    try {
      await action();
      setConfirm(null);
      setFeedback({ type: 'success', text: success });
    } catch (error) {
      console.error('Duty week action failed', error);
      setConfirm(null);
      setFeedback({ type: 'error', text: messageFor(error) });
    } finally {
      setPending('');
    }
  };

  const confirmCopy = {
    submit: {
      title: week.missingParticipants
        ? `Còn ${week.missingParticipants} công tác chưa có thành phần. Vẫn nộp Ban Giám hiệu duyệt?`
        : `Nộp lịch tuần ${formatWeekRange(week.weekStart)} cho Ban Giám hiệu duyệt?`,
      label: 'Nộp duyệt',
      action: () => submit({ weekStart: week.weekStart }),
      success: 'Đã nộp lịch tuần. Ban Giám hiệu sẽ nhận được thông báo.',
    },
    approve: {
      title: `Duyệt lịch công tác tuần ${formatWeekRange(week.weekStart)}? Giáo viên sẽ thấy lịch và nhận thông báo.`,
      label: 'Duyệt lịch tuần',
      action: () => approve({ weekStart: week.weekStart, submittedAt: week.submittedAt }),
      success: 'Đã duyệt lịch tuần.',
    },
    discard: {
      title: 'Hủy mọi thay đổi chưa duyệt và quay về bản Ban Giám hiệu đã duyệt?',
      label: 'Hủy thay đổi',
      action: () => discard({ weekStart: week.weekStart }),
      success: 'Đã quay về bản đã duyệt.',
    },
  };
  const activeConfirm = confirm && confirm !== 'return' ? confirmCopy[confirm] : null;

  return (
    <section className={`lct-week-status is-${week.status}`} aria-label="Trạng thái duyệt lịch tuần">
      <div className="lct-week-status-main">
        <span className="lct-week-pill">{pill}</span>
        <div className="lct-week-copy">
          <p>{copy.text}</p>
          {copy.hint ? <small>{copy.hint}</small> : null}
          {showChanges ? <ChangeList changes={week.changes} /> : null}
        </div>
        <div className="lct-week-actions">
          {canDiscard ? (
            <button type="button" className="work-ghost-button" disabled={Boolean(pending)} onClick={() => setConfirm('discard')}>
              Hủy thay đổi
            </button>
          ) : null}
          {canSend ? (
            <button type="button" className="work-primary-button" disabled={Boolean(pending)} onClick={() => setConfirm('submit')}>
              {week.status === 'returned' ? 'Nộp lại' : week.hasApprovedVersion ? 'Nộp duyệt lại' : 'Nộp BGH duyệt'}
            </button>
          ) : null}
          {canDecide ? (
            <>
              <button type="button" className="work-ghost-button lct-week-return" disabled={Boolean(pending)} onClick={() => setConfirm('return')}>
                Trả lại
              </button>
              <button type="button" className="work-primary-button" disabled={Boolean(pending)} onClick={() => setConfirm('approve')}>
                Duyệt lịch tuần
              </button>
            </>
          ) : null}
        </div>
      </div>
      {feedback.text ? (
        <p className={`work-feedback ${feedback.type}`} role="status" aria-live="polite">{feedback.text}</p>
      ) : null}
      {activeConfirm ? (
        <ConfirmActionModal
          title={activeConfirm.title}
          confirmLabel={activeConfirm.label}
          pending={pending === confirm}
          onCancel={() => setConfirm(null)}
          onConfirm={() => void run(confirm, activeConfirm.action, activeConfirm.success)}
        />
      ) : null}
      {confirm === 'return' ? (
        <ReturnDialog
          week={week}
          pending={pending === 'return'}
          onCancel={() => setConfirm(null)}
          onConfirm={(note) =>
            void run(
              'return',
              () => returnWeek({ weekStart: week.weekStart, submittedAt: week.submittedAt, note }),
              'Đã trả lại lịch tuần cho văn thư.',
            )}
        />
      ) : null}
    </section>
  );
}
