import { useEffect, useId, useState } from 'react';
import { useMutation, useQuery } from 'convex/react';
import { anyApi } from 'convex/server';
import { messageFor } from '../lib/appErrorMessage';
import CollapsibleMultiCheckList from '../lib/CollapsibleMultiCheckList.jsx';
import { EditActionConfirm } from '../lib/ConfirmActionModal';
import DutyEditorFields from './DutyEditorFields';
import {
  applyDutyEndDateTime,
  applyDutyFormField,
  applyDutyStartDateTime,
  dutyFormFromItem,
  dutyFormHasParticipants,
  dutyPayloadFromForm,
} from './dutyDisplay';

export default function DutyEditModal({ duty, onClose, onSaved = null }) {
  const titleId = useId();
  const options = useQuery(anyApi.duties.formOptions);
  const update = useMutation(anyApi.duties.update);
  const [form, setForm] = useState(() => dutyFormFromItem(duty));
  const [pending, setPending] = useState('');
  const [feedback, setFeedback] = useState({ type: '', text: '' });
  const [editConfirm, setEditConfirm] = useState(null);
  const includeDepartments = Boolean(options?.isOps);

  useEffect(() => {
    setForm(dutyFormFromItem(duty));
    setFeedback({ type: '', text: '' });
    setEditConfirm(null);
  }, [duty?._id]);

  useEffect(() => {
    const onKey = (event) => {
      if (event.key !== 'Escape' || pending || editConfirm) return;
      onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, pending, editConfirm]);

  const setField = (field, value) => {
    setForm((prev) => applyDutyFormField(prev, field, value));
  };

  const persistDuty = async () => {
    if (pending === 'save' || !duty?._id) return;
    const payload = dutyPayloadFromForm(form, { includeDepartments });
    if (!includeDepartments && !dutyFormHasParticipants(form, { includeDepartments })) {
      setFeedback({ type: 'error', text: 'Vui lòng chọn phòng ban, cá nhân tham gia, hoặc điền thành phần khác.' });
      return;
    }
    setPending('save');
    setFeedback({ type: '', text: '' });
    try {
      await update({ id: duty._id, ...payload });
      onSaved?.();
      onClose();
    } catch (error) {
      console.error('Duty inline update failed', error);
      setFeedback({ type: 'error', text: messageFor(error) });
    } finally {
      setPending('');
    }
  };

  const submit = (event) => {
    event.preventDefault();
    if (!includeDepartments && !dutyFormHasParticipants(form, { includeDepartments })) {
      setFeedback({ type: 'error', text: 'Vui lòng chọn phòng ban, cá nhân tham gia, hoặc điền thành phần khác.' });
      return;
    }
    setEditConfirm('save');
  };

  return (
    <div className="duty-edit-scope">
      <div
        className="duty-edit-backdrop"
        role="presentation"
        onClick={pending ? undefined : onClose}
      >
        <form
          className="duty-edit-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby={titleId}
          onClick={(event) => event.stopPropagation()}
          onSubmit={submit}
        >
          <div className="work-editor-title duty-edit-modal-header">
            <div>
              <span>CẬP NHẬT LỊCH</span>
              <h3 id={titleId}>Sửa công tác</h3>
            </div>
            <button type="button" className="duty-editor-close" onClick={onClose} aria-label="Đóng biểu mẫu">
              <span aria-hidden="true">×</span> Đóng
            </button>
          </div>

          <div className="duty-edit-modal-body duty-modern-editor">
            {options === undefined ? (
              <p className="lct-loading">Đang tải biểu mẫu sửa công tác…</p>
            ) : (
              <DutyEditorFields
                form={form}
                onField={setField}
                onStartDateTime={(date, time) => setForm((prev) => applyDutyStartDateTime(prev, date, time))}
                onEndDateTime={(date, time) => setForm((prev) => applyDutyEndDateTime(prev, date, time))}
              >
                {includeDepartments ? (
                  <div className="duty-field">
                    <span className="duty-field-label">Phòng ban tham gia</span>
                    <CollapsibleMultiCheckList
                      title="Chọn phòng ban"
                      options={options.departments}
                      values={form.departmentIds}
                      onChange={(ids) => setField('departmentIds', ids)}
                      getLabel={(department) => `${department.name}${department.code ? ` (${department.code})` : ''}`}
                      searchPlaceholder="Tìm phòng ban…"
                      emptyText="Chưa có phòng ban."
                    />
                  </div>
                ) : null}
                <div className="duty-field">
                  <span className="duty-field-label">{includeDepartments ? 'Cá nhân tham gia' : 'Người tham gia'}</span>
                  <CollapsibleMultiCheckList
                    title={includeDepartments ? 'Chọn cá nhân' : 'Chọn người tham gia'}
                    options={options.users}
                    values={form.participantUserIds}
                    onChange={(ids) => setField('participantUserIds', ids)}
                    getLabel={(user) => `${user.name || '—'} · ${user.email || ''}`}
                    searchPlaceholder="Tìm theo tên, email…"
                    emptyText={includeDepartments ? 'Chưa có người dùng.' : 'Chưa có người tham gia trong phòng ban.'}
                  />
                </div>
              </DutyEditorFields>
            )}

            {feedback.text ? (
              <div className={`work-feedback ${feedback.type}`} role="status" aria-live="polite">
                {feedback.text}
              </div>
            ) : null}
          </div>

          <div className="work-editor-actions duty-editor-actions duty-edit-modal-footer">
            <button type="button" className="work-ghost-button" onClick={() => setEditConfirm('cancel')} disabled={Boolean(pending)}>
              Hủy sửa
            </button>
            <button className="work-primary-button" disabled={Boolean(pending) || options === undefined}>
              {pending === 'save' ? 'Đang lưu…' : 'Lưu thay đổi'}
            </button>
          </div>
        </form>
      </div>
      <EditActionConfirm
        action={editConfirm}
        pending={pending === 'save'}
        onDismiss={() => setEditConfirm(null)}
        onConfirmCancel={onClose}
        onConfirmSave={() => {
          setEditConfirm(null);
          void persistDuty();
        }}
      />
    </div>
  );
}
