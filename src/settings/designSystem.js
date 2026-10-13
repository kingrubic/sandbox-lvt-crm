/**
 * Content of the "Thư viện giao diện" design-system page. Mirrors DESIGN.md;
 * tests check every token value against :root in src/styles.css.
 */

export const DESIGN_SECTIONS = [
  { id: 'mau-sac', number: 1, title: 'Màu sắc', lead: 'Chỉ dùng token. Tỉ lệ khuyên dùng: khoảng 80% trung tính, 15% navy/blue/teal, 5% màu trạng thái.' },
  { id: 'chu', number: 2, title: 'Chữ', lead: 'Montserrat cho mọi nơi; riêng bảng Lịch công tác dùng Times New Roman. Chữ người dùng phải đọc không nhỏ hơn 12px, ô nhập 14px.' },
  { id: 'khoang-cach', number: 3, title: 'Khoảng cách, bo góc, đổ bóng', lead: 'Khoảng cách theo bước 4px. Bo góc theo loại thành phần, không đặt giá trị lẻ.' },
  { id: 'nut-bam', number: 4, title: 'Nút bấm', lead: 'Mỗi vùng chỉ một nút chính. Hành động nguy hiểm luôn có bước xác nhận.' },
  { id: 'bieu-mau', number: 5, title: 'Biểu mẫu', lead: 'Nhãn nằm trên ô nhập, không dùng placeholder thay nhãn. Lỗi hiện ngay dưới ô, bằng chữ tiếng Việt.' },
  { id: 'card-bang', number: 6, title: 'Card, bảng, danh sách', lead: 'Card nền trắng, viền mảnh, bo 12px, không lồng card trong card. Bảng cuộn ngang trên điện thoại.' },
  { id: 'phan-hoi', number: 7, title: 'Phản hồi, trạng thái rỗng', lead: 'Mỗi màn hình có đủ: đang tải, rỗng, lỗi, có dữ liệu. Nói rõ chuyện gì vừa xảy ra và bước tiếp theo.' },
  { id: 'bo-cuc', number: 8, title: 'Bố cục, responsive', lead: 'Sidebar trái, header, vùng nội dung. Hai mốc màn hình: 900px và 680px.' },
  { id: 'noi-dung', number: 9, title: 'Truy cập, nội dung', lead: 'Tương phản đủ đọc, dùng được bằng bàn phím, văn phong tiếng Việt ngắn gọn và thống nhất thuật ngữ.' },
  { id: 'native', number: 10, title: 'Native Android/iOS', lead: 'Cùng ý nghĩa màu với web: navy hành động chính, teal tích cực, gold chờ, coral lỗi. Luôn có nhãn chữ.' },
];

export const COLOR_TOKENS = [
  { token: '--lvt-navy', value: '#14355f', use: 'Tiêu đề, nút chính, mục đang chọn' },
  { token: '--lvt-teal', value: '#138f7b', use: 'Nhấn tích cực, hoàn thành (nền, viền, icon)' },
  { token: '--lvt-teal-text', value: '#0e7363', use: 'Chữ màu teal (liên kết, nhãn tích cực)' },
  { token: '--lvt-blue', value: '#28639a', use: 'Liên kết, thông tin' },
  { token: '--lvt-coral', value: '#e36d55', use: 'Lỗi, quá hạn, hành động nguy hiểm' },
  { token: '--lvt-coral-strong', value: '#c0472f', use: 'Nền đặc có chữ trắng (badge số đếm)' },
  { token: '--lvt-gold', value: '#e9ad43', use: 'Cảnh báo, chờ xử lý' },
  { token: '--lvt-ink', value: '#16243e', use: 'Chữ chính' },
  { token: '--lvt-ink-soft', value: '#2b465e', use: 'Chữ phụ đậm, giá trị trong form' },
  { token: '--lvt-muted', value: '#5a6b7c', use: 'Chữ phụ, chú thích' },
  { token: '--lvt-line', value: '#dce5eb', use: 'Viền, đường kẻ' },
  { token: '--lvt-page', value: '#f4f7f8', use: 'Nền trang' },
  { token: '--lvt-paper', value: '#fffdf7', use: 'Nền thẻ ấm' },
  { token: '--lvt-surface', value: '#fbfcfc', use: 'Nền ô nhập, khối phụ trên card trắng' },
  { token: '--lvt-surface-muted', value: '#eef2f5', use: 'Nền hover, nền trung tính nhạt' },
];

export const STATUS_PAIRS = [
  { label: 'Hoàn thành', text: '--lvt-success-text', bg: '--lvt-success-bg', note: 'Hoàn thành, hợp lệ, đã duyệt' },
  { label: 'Chờ duyệt', text: '--lvt-warning-text', bg: '--lvt-warning-bg', note: 'Chờ xử lý, cảnh báo' },
  { label: 'Quá hạn', text: '--lvt-danger-text', bg: '--lvt-danger-bg', note: 'Lỗi, quá hạn, bị từ chối' },
  { label: 'Thông tin', text: '--lvt-blue', bg: '--lvt-info-bg', note: 'Thông tin trung tính' },
];

export const TYPE_SCALE = [
  { role: 'Tiêu đề trang', sample: 'Lịch công tác', size: 22, weight: 800, spec: '22–26px · 800 (mobile 19px)' },
  { role: 'Tiêu đề khối, card', sample: 'Công tác gần đến hạn', size: 16, weight: 800, spec: '15–17px · 800' },
  { role: 'Nội dung, ô nhập, bảng', sample: 'Họp tổ chuyên môn Toán lúc 14g00 tại Phòng họp 1.', size: 14, weight: 500, spec: '14px · 400–600' },
  { role: 'Nhãn, chú thích', sample: 'Cập nhật lúc 10:20, 12/10', size: 12, weight: 600, spec: '12–13px · 600–700', muted: true },
  { role: 'Nhãn nhóm viết hoa', sample: 'CHỨC NĂNG CHÍNH', size: 11, weight: 800, spec: '10–11px · 800 · giãn chữ', muted: true },
];

export const SPACING_STEPS = [4, 8, 12, 16, 20, 24, 32];

export const RADII = [
  { label: 'Ô nhập, nút', value: '8px' },
  { label: 'Card, panel', value: '12px' },
  { label: 'Modal', value: '16px' },
  { label: 'Pill, badge', value: '999px' },
];

export const BREAKPOINTS = [
  { width: '> 900px', note: 'Máy tính: sidebar 256px, nội dung nhiều cột.' },
  { width: '≤ 900px', note: 'Máy tính bảng: sidebar thu còn 244px.' },
  { width: '≤ 680px', note: 'Điện thoại: sidebar thành ngăn trượt, form một cột, lề 16px, không cuộn ngang.' },
];

export const WRITING_EXAMPLES = [
  { good: 'Lưu', bad: 'OK', why: 'Nhãn nút là động từ ngắn.' },
  { good: 'Không tải được danh sách. Hãy thử lại.', bad: 'Error 500: INTERNAL', why: 'Không hiện mã lỗi thô cho người dùng.' },
  { good: 'Chưa có công tác nào trong tuần này.', bad: '(trống)', why: 'Trạng thái rỗng nói rõ vì sao.' },
  { good: 'Quá hạn', bad: 'chỉ tô đỏ, không có chữ', why: 'Không bao giờ chỉ dựa vào màu.' },
];

/** The archived prototype is fake data; it opens only after an explicit acknowledgement. */
export function canOpenPrototypeArchive(acknowledged) {
  return acknowledged === true;
}
