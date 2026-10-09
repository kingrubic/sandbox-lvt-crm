/**
 * Tiện ích thuần cho Thiết lập năm học: gợi ý ngày lễ Việt Nam, gom đợt nghỉ, thống kê ngày học.
 * Âm lịch dùng thuật toán thiên văn của Hồ Ngọc Đức (múi giờ +7) — chuẩn phổ biến cho lịch Việt.
 * Các khoảng nghỉ gợi ý chỉ để điền sẵn; admin luôn xem và chỉnh trước khi lưu.
 */
import { addDays, weekdayIndex } from '../homeroom/homeroomLabels.js';

const TZ = 7;

export function isWeekend(ymd) {
  const day = weekdayIndex(ymd);
  return day === 0 || day === 6;
}

/** Số ngày Thứ 2 – Thứ 6 trong khoảng (đầu cuối tính cả). */
export function weekdaysBetween(from, to) {
  const list = [];
  for (let day = from; day <= to; day = addDays(day, 1)) if (!isWeekend(day)) list.push(day);
  return list;
}

/**
 * Gom các ngày nghỉ liên tiếp cùng ghi chú thành "đợt nghỉ" (cuối tuần xen giữa không cắt đợt).
 * Trả về [{ note, from, to, dates }], sắp theo ngày.
 */
export function groupHolidayRuns(days) {
  const holidays = days.filter((row) => row.kind === 'holiday').sort((a, b) => a.date.localeCompare(b.date));
  const runs = [];
  for (const row of holidays) {
    const last = runs[runs.length - 1];
    const contiguous = last && last.note === (row.note || '') && weekdaysBetween(addDays(last.to, 1), addDays(row.date, -1)).length === 0;
    if (contiguous) {
      last.to = row.date;
      last.dates.push(row.date);
    } else {
      runs.push({ note: row.note || '', from: row.date, to: row.date, dates: [row.date] });
    }
  }
  return runs;
}

/** Thống kê toàn năm: ngày học thực tế, ngày nghỉ lễ rơi vào ngày thường, ngày học bù, số tuần. */
export function schoolYearStats(year, days) {
  const byDate = new Map(days.map((row) => [row.date, row.kind]));
  let schoolDays = 0;
  let holidays = 0;
  let extra = 0;
  for (let day = year.startDate; day <= year.endDate; day = addDays(day, 1)) {
    const kind = byDate.get(day);
    const weekend = isWeekend(day);
    if (kind === 'holiday') {
      if (!weekend) holidays += 1;
    } else if (!weekend || kind === 'extra_teaching' || kind === 'working') {
      schoolDays += 1;
      if (weekend) extra += 1;
    }
  }
  const spanDays = Math.round((Date.parse(`${year.endDate}T00:00:00Z`) - Date.parse(`${year.startDate}T00:00:00Z`)) / 86400000) + 1;
  return { schoolDays, holidays, extra, weeks: Math.ceil(spanDays / 7) };
}

function jdFromDate(dd, mm, yy) {
  const a = Math.floor((14 - mm) / 12);
  const y = yy + 4800 - a;
  const m = mm + 12 * a - 3;
  return dd + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - Math.floor(y / 100) + Math.floor(y / 400) - 32045;
}

function jdToYmd(jd) {
  const a = jd + 32044;
  const b = Math.floor((4 * a + 3) / 146097);
  const c = a - Math.floor((b * 146097) / 4);
  const d = Math.floor((4 * c + 3) / 1461);
  const e = c - Math.floor((1461 * d) / 4);
  const m = Math.floor((5 * e + 2) / 153);
  const day = e - Math.floor((153 * m + 2) / 5) + 1;
  const month = m + 3 - 12 * Math.floor(m / 10);
  const year = b * 100 + d - 4800 + Math.floor(m / 10);
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

function newMoonDay(k) {
  const T = k / 1236.85;
  const T2 = T * T;
  const T3 = T2 * T;
  const dr = Math.PI / 180;
  let jd1 = 2415020.75933 + 29.53058868 * k + 0.0001178 * T2 - 0.000000155 * T3;
  jd1 += 0.00033 * Math.sin((166.56 + 132.87 * T - 0.009173 * T2) * dr);
  const M = 359.2242 + 29.10535608 * k - 0.0000333 * T2 - 0.00000347 * T3;
  const Mpr = 306.0253 + 385.81691806 * k + 0.0107306 * T2 + 0.00001236 * T3;
  const F = 21.2964 + 390.67050646 * k - 0.0016528 * T2 - 0.00000239 * T3;
  let c1 = (0.1734 - 0.000393 * T) * Math.sin(M * dr) + 0.0021 * Math.sin(2 * dr * M);
  c1 = c1 - 0.4068 * Math.sin(Mpr * dr) + 0.0161 * Math.sin(dr * 2 * Mpr);
  c1 -= 0.0004 * Math.sin(dr * 3 * Mpr);
  c1 = c1 + 0.0104 * Math.sin(dr * 2 * F) - 0.0051 * Math.sin(dr * (M + Mpr));
  c1 = c1 - 0.0074 * Math.sin(dr * (M - Mpr)) + 0.0004 * Math.sin(dr * (2 * F + M));
  c1 = c1 - 0.0004 * Math.sin(dr * (2 * F - M)) - 0.0006 * Math.sin(dr * (2 * F + Mpr));
  c1 = c1 + 0.001 * Math.sin(dr * (2 * F - Mpr)) + 0.0005 * Math.sin(dr * (2 * Mpr + M));
  const deltat = T < -11
    ? 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3
    : -0.000278 + 0.000265 * T + 0.000262 * T2;
  return Math.floor(jd1 + c1 - deltat + 0.5 + TZ / 24);
}

function sunLongitudeSector(jdn) {
  const T = (jdn - 0.5 - TZ / 24 - 2451545.0) / 36525;
  const T2 = T * T;
  const dr = Math.PI / 180;
  const M = 357.5291 + 35999.0503 * T - 0.0001559 * T2 - 0.00000048 * T * T2;
  const L0 = 280.46645 + 36000.76983 * T + 0.0003032 * T2;
  let DL = (1.9146 - 0.004817 * T - 0.000014 * T2) * Math.sin(dr * M);
  DL = DL + (0.019993 - 0.000101 * T) * Math.sin(dr * 2 * M) + 0.00029 * Math.sin(dr * 3 * M);
  let L = (L0 + DL) * dr;
  L -= Math.PI * 2 * Math.floor(L / (Math.PI * 2));
  return Math.floor((L / Math.PI) * 6);
}

function lunarMonth11(yy) {
  const k = Math.floor((jdFromDate(31, 12, yy) - 2415021) / 29.530588853);
  const nm = newMoonDay(k);
  return sunLongitudeSector(nm) >= 9 ? newMoonDay(k - 1) : nm;
}

function leapMonthOffset(a11) {
  const k = Math.floor((a11 - 2415021.076998695) / 29.530588853 + 0.5);
  let i = 1;
  let arc = sunLongitudeSector(newMoonDay(k + i));
  let last;
  do {
    last = arc;
    i += 1;
    arc = sunLongitudeSector(newMoonDay(k + i));
  } while (arc !== last && i < 14);
  return i - 1;
}

/** Ngày âm lịch (tháng thường, không nhuận) → YYYY-MM-DD dương lịch. */
export function lunarToSolar(lunarDay, lunarMonth, lunarYear) {
  const a11 = lunarMonth < 11 ? lunarMonth11(lunarYear - 1) : lunarMonth11(lunarYear);
  const b11 = lunarMonth < 11 ? lunarMonth11(lunarYear) : lunarMonth11(lunarYear + 1);
  const k = Math.floor(0.5 + (a11 - 2415021.076998695) / 29.530588853);
  let off = lunarMonth - 11;
  if (off < 0) off += 12;
  if (b11 - a11 > 365 && off >= leapMonthOffset(a11)) off += 1;
  return jdToYmd(newMoonDay(k + off) + lunarDay - 1);
}

/**
 * Danh sách gợi ý trong khoảng [startDate, endDate] của năm học (đã cắt theo biên năm học).
 * Mỗi mục: { key, name, from, to, hint }.
 */
export function suggestVietnamHolidays(startDate, endDate) {
  const firstYear = Number(startDate.slice(0, 4));
  const lastYear = Number(endDate.slice(0, 4));
  const list = [];
  for (let y = firstYear; y <= lastYear; y += 1) {
    const tet = lunarToSolar(1, 1, y);
    list.push(
      { key: `quockhanh-${y}`, name: 'Nghỉ lễ Quốc khánh 2/9', from: `${y}-09-01`, to: `${y}-09-02`, hint: '1/9 – 2/9 dương lịch' },
      { key: `duonglich-${y}`, name: 'Nghỉ Tết Dương lịch', from: `${y}-01-01`, to: `${y}-01-01`, hint: '1/1 dương lịch' },
      { key: `tet-${y}`, name: 'Nghỉ Tết Nguyên đán', from: addDays(tet, -2), to: addDays(tet, 4), hint: `Mùng 1 Tết: ${tet.slice(8)}/${tet.slice(5, 7)}/${y} — gợi ý nghỉ từ 2 ngày trước Tết đến mùng 5` },
      { key: `gioto-${y}`, name: 'Giỗ Tổ Hùng Vương (10/3 âm lịch)', from: lunarToSolar(10, 3, y), to: lunarToSolar(10, 3, y), hint: '10/3 âm lịch' },
      { key: `3004-${y}`, name: 'Nghỉ lễ 30/4 – 1/5', from: `${y}-04-30`, to: `${y}-05-01`, hint: 'Giải phóng miền Nam & Quốc tế Lao động' },
    );
  }
  return list
    .filter((item) => item.to >= startDate && item.from <= endDate)
    .map((item) => ({
      ...item,
      from: item.from < startDate ? startDate : item.from,
      to: item.to > endDate ? endDate : item.to,
    }))
    .sort((a, b) => a.from.localeCompare(b.from));
}
