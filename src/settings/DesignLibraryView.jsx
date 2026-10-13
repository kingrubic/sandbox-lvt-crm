import React, { useEffect, useId, useRef, useState } from 'react';
import { useConvexAuth } from '@convex-dev/auth/react';
import {
  DESIGN_LIBRARY_URL,
  designLibraryErrorMessage,
  prepareDesignLibraryDocument,
} from './designLibrary.js';
import {
  BREAKPOINTS,
  COLOR_TOKENS,
  DESIGN_SECTIONS,
  RADII,
  SPACING_STEPS,
  STATUS_PAIRS,
  TYPE_SCALE,
  WRITING_EXAMPLES,
  canOpenPrototypeArchive,
} from './designSystem.js';
import '../work/work.css';
import './designLibrary.css';

/** Illustration only: `inert` keeps every control in the sample unclickable and unfocusable. */
function Sample({ name, children, className = '' }) {
  return (
    <div className={`ds-sample ${className}`.trim()}>
      <span className="ds-sample-tag">
        <b>MẪU</b> · {name}
      </span>
      <div className="ds-sample-body" inert>
        {children}
      </div>
    </div>
  );
}

function Spec({ items }) {
  return (
    <dl className="ds-spec">
      {items.map(([term, detail]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{detail}</dd>
        </div>
      ))}
    </dl>
  );
}

function Section({ id, children }) {
  const section = DESIGN_SECTIONS.find((item) => item.id === id);
  return (
    <section className="ds-section" id={`ds-${id}`} aria-labelledby={`ds-${id}-title`}>
      <h2 id={`ds-${id}-title`}>
        <span>{section.number}</span>
        {section.title}
      </h2>
      <p className="ds-lead">{section.lead}</p>
      {children}
    </section>
  );
}

function PrototypeArchive() {
  const { fetchAccessToken } = useConvexAuth();
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  const [acknowledged, setAcknowledged] = useState(false);
  const [state, setState] = useState({ status: 'closed', html: '', error: '' });
  const frameRef = useRef(null);

  useEffect(() => {
    if (!confirming) return undefined;
    const onKey = (event) => {
      if (event.key === 'Escape') setConfirming(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [confirming]);

  const open = async () => {
    if (!canOpenPrototypeArchive(acknowledged)) return;
    setConfirming(false);
    setState({ status: 'loading', html: '', error: '' });
    try {
      const token = await fetchAccessToken({ forceRefreshToken: false });
      if (!token) throw Object.assign(new Error('UNAUTHORIZED'), { status: 401 });
      const response = await fetch(DESIGN_LIBRARY_URL, {
        headers: { Authorization: `Bearer ${token}` },
        cache: 'no-store',
      });
      if (!response.ok) throw Object.assign(new Error('DESIGN_LIBRARY_FAILED'), { status: response.status });
      const html = prepareDesignLibraryDocument(await response.text());
      setState({ status: 'ready', html, error: '' });
      window.requestAnimationFrame(() => frameRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
    } catch (error) {
      setState({ status: 'error', html: '', error: designLibraryErrorMessage(error?.status) });
    }
  };

  const close = () => {
    setState({ status: 'closed', html: '', error: '' });
    setAcknowledged(false);
  };

  if (state.status === 'closed' || state.status === 'error') {
    return (
      <div className="ds-archive">
        <button type="button" className="ds-archive-toggle" onClick={() => { setAcknowledged(false); setConfirming(true); }}>
          <span>
            <b>Lưu trữ cho người làm giao diện</b> · Bản prototype gốc (đã cũ)
          </span>
          <span aria-hidden="true">Mở ▸</span>
        </button>
        {state.status === 'error' ? <p className="ds-archive-error" role="status">{state.error}</p> : null}
        {confirming ? (
          <div className="ds-modal-backdrop" role="presentation" onClick={() => setConfirming(false)}>
            <section
              className="ds-modal"
              role="dialog"
              aria-modal="true"
              aria-labelledby={titleId}
              onClick={(event) => event.stopPropagation()}
            >
              <span className="ds-modal-kicker">CẢNH BÁO</span>
              <h3 id={titleId}>Mở bản prototype gốc?</h3>
              <p>
                Đây là <b>bản dựng thử với dữ liệu giả</b> từ giai đoạn thiết kế. Các màn hình trong đó{' '}
                <b>không phải chức năng của hệ thống</b>, mọi nút bấm đều không có tác dụng.
              </p>
              <label className="ds-ack">
                <input
                  type="checkbox"
                  checked={acknowledged}
                  onChange={(event) => setAcknowledged(event.target.checked)}
                />
                <span>Tôi hiểu đây chỉ là bản tham khảo cho người làm giao diện.</span>
              </label>
              <div className="ds-modal-actions">
                <button type="button" className="work-ghost-button" onClick={() => setConfirming(false)}>
                  Hủy
                </button>
                <button
                  type="button"
                  className="work-primary-button"
                  disabled={!canOpenPrototypeArchive(acknowledged)}
                  onClick={() => void open()}
                >
                  Mở bản lưu trữ
                </button>
              </div>
            </section>
          </div>
        ) : null}
      </div>
    );
  }

  return (
    <div className="ds-archive-open" ref={frameRef}>
      <div className="ds-archive-stripe" role="note">
        <span>⚠ BẢN PROTOTYPE GỐC · DỮ LIỆU GIẢ · KHÔNG PHẢI CHỨC NĂNG THẬT</span>
        <button type="button" onClick={close}>Đóng</button>
      </div>
      {state.status === 'loading' ? (
        <div className="ds-archive-loading">Đang tải bản lưu trữ…</div>
      ) : (
        <div className="ds-archive-frame-wrap">
          <iframe
            className="ds-archive-frame"
            title="Bản prototype gốc (dữ liệu giả)"
            sandbox="allow-scripts"
            referrerPolicy="no-referrer"
            srcDoc={state.html}
          />
          <span className="ds-archive-watermark" aria-hidden="true">BẢN DỰNG THỬ · DỮ LIỆU GIẢ</span>
        </div>
      )}
    </div>
  );
}

export default function DesignLibraryView() {
  const [activeId, setActiveId] = useState(DESIGN_SECTIONS[0].id);

  const jump = (id) => {
    setActiveId(id);
    document.getElementById(`ds-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  return (
    <section className="ds-page" aria-label="Thư viện giao diện">
      <div className="ds-intro" role="note">
        <span className="ds-intro-icon" aria-hidden="true">ⓘ</span>
        <div>
          <b>Tài liệu quy chuẩn giao diện, không phải chức năng của hệ thống</b>
          <p>
            Trang này cho người làm giao diện tra cứu màu, chữ và thành phần dùng chung. Các khung có nhãn <b>MẪU</b> chỉ để
            minh họa, bấm vào không làm gì. Nội dung khớp với <code>DESIGN.md</code>.
          </p>
        </div>
      </div>

      <div className="ds-layout">
        <nav className="ds-toc" aria-label="Mục lục">
          {DESIGN_SECTIONS.map((section) => (
            <button
              key={section.id}
              type="button"
              className={activeId === section.id ? 'is-active' : undefined}
              onClick={() => jump(section.id)}
            >
              {section.number}. {section.title}
            </button>
          ))}
        </nav>

        <div className="ds-content">
          <Section id="mau-sac">
            <div className="ds-swatches">
              {COLOR_TOKENS.map((color) => (
                <div className="ds-swatch" key={color.token}>
                  <span className="ds-swatch-chip" style={{ background: `var(${color.token})` }} />
                  <span className="ds-swatch-text">
                    <code>{color.token}</code> <small>{color.value}</small>
                    <span>{color.use}</span>
                  </span>
                </div>
              ))}
            </div>
            <div className="ds-pairs">
              {STATUS_PAIRS.map((pair) => (
                <div className="ds-pair" key={pair.label} style={{ color: `var(${pair.text})`, background: `var(${pair.bg})` }}>
                  <b>{pair.label}</b>
                  <code>{pair.text}</code>
                  <span>{pair.note}</span>
                </div>
              ))}
            </div>
          </Section>

          <Section id="chu">
            <div className="ds-type">
              {TYPE_SCALE.map((row) => (
                <div className="ds-type-row" key={row.role}>
                  <span className="ds-type-role">{row.role}</span>
                  <span
                    className={row.muted ? 'ds-type-sample is-muted' : 'ds-type-sample'}
                    style={{ fontSize: `${row.size}px`, fontWeight: row.weight, letterSpacing: row.size < 12 ? '.1em' : undefined }}
                  >
                    {row.sample}
                  </span>
                  <code>{row.spec}</code>
                </div>
              ))}
            </div>
            <Sample name="Ngoại lệ Times New Roman">
              <p className="ds-times">LỊCH CÔNG TÁC TỪ NGÀY 19/10/2026 ĐẾN 24/10/2026</p>
            </Sample>
            <p className="ds-note">Chỉ bảng lịch chính thức của Lịch công tác (quốc hiệu, bảng, bản in/PDF) dùng Times New Roman.</p>
          </Section>

          <Section id="khoang-cach">
            <div className="ds-spacing">
              {SPACING_STEPS.map((step) => (
                <div key={step}>
                  <span className="ds-spacing-bar" style={{ width: `${step * 4}px` }} />
                  <code>{step}px</code>
                </div>
              ))}
            </div>
            <div className="ds-radii">
              {RADII.map((radius) => (
                <div key={radius.label}>
                  <span className="ds-radius-box" style={{ borderRadius: radius.value }} />
                  <b>{radius.value}</b>
                  <span>{radius.label}</span>
                </div>
              ))}
              <div>
                <span className="ds-radius-box is-shadow" />
                <b>Đổ bóng nhẹ</b>
                <span>Ám màu navy, focus ring teal</span>
              </div>
            </div>
          </Section>

          <Section id="nut-bam">
            <Sample name="Nút bấm">
              <div className="ds-row">
                <button type="button" className="work-primary-button">Lưu thay đổi</button>
                <button type="button" className="work-ghost-button">Hủy</button>
                <button type="button" className="work-ghost-button ds-danger">Xóa</button>
                <button type="button" className="work-primary-button" disabled>Đang lưu…</button>
              </div>
            </Sample>
            <Spec
              items={[
                ['Nút chính', 'Hành động chính của vùng: Lưu, Nộp, Duyệt. Mỗi vùng chỉ một nút.'],
                ['Nút phụ', 'Hủy, Quay lại, Tải PDF. Viền mảnh, chữ navy.'],
                ['Nút nguy hiểm', 'Xóa, Trả lại, Khóa. Màu coral, luôn hỏi lại.'],
                ['Đang xử lý', 'Khóa nút, đổi chữ thành "Đang …", không cho bấm lặp.'],
              ]}
            />
          </Section>

          <Section id="bieu-mau">
            <Sample name="Biểu mẫu">
              <div className="ds-form">
                <label className="ds-field">
                  <span>Tên công tác</span>
                  <input type="text" defaultValue="Họp tổ chuyên môn Toán" />
                </label>
                <label className="ds-field is-error">
                  <span>Địa điểm</span>
                  <input type="text" defaultValue="" placeholder="Ví dụ: Phòng họp 1" />
                  <small>Vui lòng nhập địa điểm.</small>
                </label>
              </div>
            </Sample>
            <Spec
              items={[
                ['Nhãn', 'Luôn nằm trên ô nhập. Placeholder chỉ là ví dụ.'],
                ['Lỗi', 'Ngay dưới ô liên quan, màu coral kèm chữ.'],
                ['Ngày', 'Hiển thị dd/mm/yyyy. Gửi lên máy chủ YYYY-MM-DD.'],
                ['Ô nhập', 'Chữ 14px, bo 8px, nền surface.'],
              ]}
            />
          </Section>

          <Section id="card-bang">
            <Sample name="Card và bảng">
              <div className="ds-card">
                <b>Công tác gần đến hạn</b>
                <span>3 công tác trong 24 giờ tới</span>
              </div>
              <div className="ds-table-wrap">
                <table className="ds-table">
                  <thead>
                    <tr><th>Lớp</th><th>Sĩ số</th><th>Trạng thái</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>6A1</td><td className="is-num">41</td><td><span className="ds-badge is-success">Đủ 41/41</span></td></tr>
                    <tr><td>7A2</td><td className="is-num">39</td><td><span className="ds-badge is-danger">3 vắng</span></td></tr>
                  </tbody>
                </table>
              </div>
            </Sample>
            <Spec
              items={[
                ['Card', 'Nền trắng hoặc paper, viền line, bo 12px. Không lồng card.'],
                ['Bảng', 'Tiêu đề cột nhỏ, đậm, màu muted. Cột số căn phải.'],
                ['Danh sách', 'Tiêu đề → bộ lọc → tóm tắt → danh sách → tải thêm.'],
                ['Điện thoại', 'Bảng cuộn ngang trong khung của nó.'],
              ]}
            />
          </Section>

          <Section id="phan-hoi">
            <Sample name="Thông báo kết quả">
              <p className="ds-feedback is-success">Đã lưu thay đổi.</p>
              <p className="ds-feedback is-error">Không tải được danh sách. Hãy thử lại.</p>
            </Sample>
            <Sample name="Trạng thái rỗng">
              <div className="ds-empty">
                <b>Lịch tuần này chưa được duyệt</b>
                <span>Nhà trường sẽ công bố lịch công tác sau khi Ban Giám hiệu duyệt.</span>
              </div>
            </Sample>
            <Spec
              items={[
                ['Đang tải', 'Câu ngắn "Đang tải …", giữ chỗ cho nội dung.'],
                ['Rỗng', 'Nói rõ vì sao và bước tiếp theo.'],
                ['Lỗi', 'Tiếng Việt dễ hiểu, kèm cách thử lại.'],
                ['Hộp xác nhận', 'Một mục đích, nút chính bên phải, đóng bằng Esc.'],
              ]}
            />
          </Section>

          <Section id="bo-cuc">
            <Sample name="Khung trang">
              <div className="ds-shell">
                <span className="ds-shell-side">Sidebar</span>
                <span className="ds-shell-head">Header</span>
                <span className="ds-shell-body">Vùng nội dung</span>
              </div>
            </Sample>
            <ul className="ds-list">
              {BREAKPOINTS.map((point) => (
                <li key={point.width}><b>{point.width}</b> {point.note}</li>
              ))}
            </ul>
          </Section>

          <Section id="noi-dung">
            <div className="ds-table-wrap">
              <table className="ds-table">
                <thead>
                  <tr><th>Nên viết</th><th>Tránh</th><th>Vì sao</th></tr>
                </thead>
                <tbody>
                  {WRITING_EXAMPLES.map((row) => (
                    <tr key={row.good}>
                      <td className="ds-good">{row.good}</td>
                      <td className="ds-bad">{row.bad}</td>
                      <td>{row.why}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="ds-note">Thuật ngữ thống nhất: Lịch công tác, Công việc, Lớp chủ nhiệm, Trao đổi, Giám thị. Ảnh có alt tiếng Việt, focus luôn nhìn thấy.</p>
          </Section>

          <Section id="native">
            <Sample name="Chip trạng thái trên app">
              <div className="ds-row">
                <span className="ds-badge is-success">Đủ 41/41</span>
                <span className="ds-badge is-warning">Chờ duyệt</span>
                <span className="ds-badge is-danger">3 vắng</span>
                <span className="ds-badge is-neutral">Chưa điểm danh</span>
              </div>
            </Sample>
            <Spec
              items={[
                ['Màu', 'Cùng ý nghĩa với web; điểm danh dùng bộ --hr-*.'],
                ['Dark mode', 'Màu theo hệ thống, không cố định chữ trắng/đen.'],
                ['Vùng chạm', 'Tối thiểu 44px.'],
                ['Phiên bản', 'Mọi thay đổi native tăng version và build number.'],
              ]}
            />
          </Section>

          <PrototypeArchive />
        </div>
      </div>
    </section>
  );
}
