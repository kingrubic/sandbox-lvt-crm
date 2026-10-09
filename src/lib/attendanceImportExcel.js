import * as XLSX from 'xlsx';

/** Mẫu = file "Bảng thống kê điểm danh học sinh toàn trường" của hệ thống camera. Tiêu đề phải khớp với convex/attendanceImportSheet.ts. */
export const ATTENDANCE_IMPORT_TEMPLATE_HEADERS = [
  'Lớp học',
  'Tên học sinh',
  'Ngày sinh',
  'Trạng thái điểm danh',
  'Thời gian điểm danh',
  'Loại điểm danh',
];

export const ATTENDANCE_IMPORT_TEMPLATE_EXAMPLE_ROWS = [
  ['7/1', 'Nguyễn Văn A', '11/03/2014', 'Đúng giờ', '06:52', 'Camera'],
  ['7/1', 'Trần Thị B', '15/11/2014', 'Đi trễ', '07:12', 'Camera'],
  ['7/2', 'Lê Văn C', '02/01/2014', 'Chưa điểm danh', '--:--', ''],
];

export const ATTENDANCE_IMPORT_TEMPLATE_INSTRUCTIONS = [
  ['File điểm danh toàn trường — xuất từ hệ thống camera, mỗi ngày một file. Chọn ngày điểm danh trên phần mềm khi nhập.'],
  ['Giữ nguyên dòng tiêu đề: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh, Thời gian điểm danh. Cột Loại điểm danh được bỏ qua.'],
  ['Học sinh được nhận diện bằng Lớp + Họ tên + Ngày sinh (dd/mm/yyyy) — phải trùng hồ sơ trên phần mềm. Lớp học phải trùng tên hoặc mã lớp trên phần mềm (7/1 được hiểu là 7-1).'],
  ['Trạng thái chỉ nhận: Đúng giờ, Đi trễ, Chưa điểm danh. Thời gian ghi giờ:phút (ví dụ 07:05), --:-- nếu chưa điểm danh.'],
  ['“Chưa điểm danh” và học sinh có trong danh sách lớp nhưng không có trong file đều được ghi “Vắng chờ xử lý”.'],
  ['Các dòng ví dụ là dữ liệu minh họa — xóa trước khi dùng.'],
];

export const ATTENDANCE_IMPORT_TEMPLATE_FILENAME = 'mau_diem_danh_toan_truong.xlsx';
export const ATTENDANCE_IMPORT_TEMPLATE_SHEET = 'diem_danh';
export const ATTENDANCE_IMPORT_TEMPLATE_INSTRUCTIONS_SHEET = 'huong_dan';

export function attendanceImportTemplateMatrix() {
  return [ATTENDANCE_IMPORT_TEMPLATE_HEADERS, ...ATTENDANCE_IMPORT_TEMPLATE_EXAMPLE_ROWS];
}

export function buildAttendanceImportTemplateWorkbook() {
  const workbook = XLSX.utils.book_new();
  const dataSheet = XLSX.utils.aoa_to_sheet(attendanceImportTemplateMatrix());
  dataSheet['!cols'] = [{ wch: 10 }, { wch: 28 }, { wch: 12 }, { wch: 22 }, { wch: 20 }, { wch: 16 }];
  const instructionSheet = XLSX.utils.aoa_to_sheet(ATTENDANCE_IMPORT_TEMPLATE_INSTRUCTIONS);
  instructionSheet['!cols'] = [{ wch: 110 }];
  XLSX.utils.book_append_sheet(workbook, dataSheet, ATTENDANCE_IMPORT_TEMPLATE_SHEET);
  XLSX.utils.book_append_sheet(workbook, instructionSheet, ATTENDANCE_IMPORT_TEMPLATE_INSTRUCTIONS_SHEET);
  return workbook;
}

export function downloadAttendanceImportTemplate() {
  XLSX.writeFile(buildAttendanceImportTemplateWorkbook(), ATTENDANCE_IMPORT_TEMPLATE_FILENAME);
}
