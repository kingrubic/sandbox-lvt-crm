export const DESIGN_LIBRARY_URL = '/api/design-library';

/** Open the prototype straight on its "Thư viện giao diện" view. */
const OPEN_COMPONENTS_VIEW = '<script>document.querySelector(\'.nav button[data-view="components"]\')?.click();</script>';

export function prepareDesignLibraryDocument(html) {
  const source = String(html || '');
  const closing = source.lastIndexOf('</body>');
  if (closing === -1) return `${source}${OPEN_COMPONENTS_VIEW}`;
  return `${source.slice(0, closing)}${OPEN_COMPONENTS_VIEW}${source.slice(closing)}`;
}

export function designLibraryErrorMessage(status) {
  if (status === 401) return 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.';
  if (status === 403) return 'Chỉ Administrator mới xem được Thư viện giao diện.';
  return 'Không tải được Thư viện giao diện. Vui lòng thử lại.';
}
