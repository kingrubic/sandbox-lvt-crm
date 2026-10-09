import { routeForPathname } from '../navigationRoutes.js';

export const CLASS_TABS = ['hoc-sinh', 'diem-danh', 'bao-cao', 'quan-ly'];

/** Map a /lop-chu-nhiem/... pathname to the homeroom view to render. */
export function parseHomeroomPath(pathname) {
  const normalized = routeForPathname(pathname)?.homeroomPath || '/lop-chu-nhiem';
  const parts = normalized.split('/').filter(Boolean);
  if (parts[1] === 'quan-ly-lop') return { view: 'manage' };
  if (parts[1] === 'vang-cho-xu-ly') return { view: 'pending' };
  if (parts[1] === 'nhap-diem-danh' || parts[1] === 'import-diem-danh') return { view: 'import' };
  if (parts[1] === 'hoc-sinh' && parts[2]) return { view: 'student', studentId: decodeURIComponent(parts[2]) };
  if (parts[1] === 'lop' && parts[2]) {
    const tab = CLASS_TABS.includes(parts[3]) ? parts[3] : 'hoc-sinh';
    return { view: 'class', classId: decodeURIComponent(parts[2]), tab };
  }
  return { view: 'overview' };
}

/** UI-level role flags; the backend re-checks every permission. */
export function homeroomRoles(session) {
  const level = session?.menuAccess?.homeroom;
  const isManager = Boolean(session?.isOperationalManager);
  const isSupervisor = !isManager && level === 'supervisor';
  return {
    isManager,
    isSupervisor,
    isViewAll: !isManager && level === 'view_all',
    canImport: isManager || level === 'supervisor',
    seesClasses: !isSupervisor,
  };
}
