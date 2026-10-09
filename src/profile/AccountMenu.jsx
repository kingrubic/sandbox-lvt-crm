import React, { useEffect, useRef, useState } from 'react';
import { useOwnAvatarContext } from './useOwnAvatar.jsx';
import './accountMenu.css';

function MenuGlyph({ children }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

function PasswordIcon() {
  return (
    <MenuGlyph>
      <rect x="5" y="11" width="14" height="10" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </MenuGlyph>
  );
}

function DevicesIcon() {
  return (
    <MenuGlyph>
      <rect x="3.5" y="4.5" width="17" height="12" rx="2" />
      <path d="M8 20.5h8" />
      <path d="M12 16.5v4" />
    </MenuGlyph>
  );
}

function GuideIcon() {
  return (
    <MenuGlyph>
      <path d="M12 6.5C9 4.5 5.5 4.5 3 5.5v14c2.5-1 6-1 9 1 3-2 6.5-2 9-1v-14c-2.5-1-6-1-9 1Z" />
      <path d="M12 6.5v14" />
    </MenuGlyph>
  );
}

function LogoutIcon() {
  return (
    <MenuGlyph>
      <path d="M10 4.5H6.5A2 2 0 0 0 4.5 6.5v11A2 2 0 0 0 6.5 19.5H10" />
      <path d="M10 12h9.5" />
      <path d="m16.5 8.5 3.5 3.5-3.5 3.5" />
    </MenuGlyph>
  );
}

function ChevronIcon() {
  return (
    <svg className="account-menu-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function AvatarFace({ avatarUrl, initials, className }) {
  return (
    <span className={`${className}${avatarUrl ? ' has-photo' : ''}`}>
      {avatarUrl ? <img src={avatarUrl} alt="" /> : initials}
    </span>
  );
}

export default function AccountMenu({ onChoose, onSignOut }) {
  const { avatarUrl, displayName, initials } = useOwnAvatarContext();
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const closeOnEscape = (event) => {
      if (event.key === 'Escape') setOpen(false);
    };
    const closeOnPointer = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    window.addEventListener('keydown', closeOnEscape);
    window.addEventListener('pointerdown', closeOnPointer);
    return () => {
      window.removeEventListener('keydown', closeOnEscape);
      window.removeEventListener('pointerdown', closeOnPointer);
    };
  }, [open]);

  const go = (menuId) => {
    setOpen(false);
    onChoose(menuId);
  };

  return (
    <div className="account-menu-wrap" ref={wrapRef}>
      <button
        type="button"
        className={`account-menu-trigger${open ? ' is-open' : ''}`}
        onClick={() => setOpen((current) => !current)}
        aria-label={`Tài khoản ${displayName}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls="account-menu"
      >
        <AvatarFace avatarUrl={avatarUrl} initials={initials} className="account-menu-avatar" />
      </button>

      {open ? (
        <div className="account-menu-popover" id="account-menu" role="menu" aria-label="Tài khoản">
          <button
            type="button"
            className="account-menu-identity"
            role="menuitem"
            onClick={() => go('profile')}
          >
            <AvatarFace avatarUrl={avatarUrl} initials={initials} className="account-menu-identity-avatar" />
            <span className="account-menu-identity-copy">
              <strong>{displayName}</strong>
              <small>Hồ sơ nội bộ</small>
            </span>
          </button>

          <div className="account-menu-list">
            <button type="button" className="account-menu-row" role="menuitem" onClick={() => go('change-password')}>
              <span className="account-menu-chip" aria-hidden="true"><PasswordIcon /></span>
              <span>Đổi mật khẩu</span>
              <ChevronIcon />
            </button>
            <button type="button" className="account-menu-row" role="menuitem" onClick={() => go('devices')}>
              <span className="account-menu-chip" aria-hidden="true"><DevicesIcon /></span>
              <span>Quản lý thiết bị đăng nhập</span>
              <ChevronIcon />
            </button>
            <a
              className="account-menu-row"
              role="menuitem"
              href="/huong-dan-su-dung.html"
              target="_blank"
              rel="noopener noreferrer"
              aria-label="Hướng dẫn sử dụng (mở trong tab mới)"
              onClick={() => setOpen(false)}
            >
              <span className="account-menu-chip" aria-hidden="true"><GuideIcon /></span>
              <span>Hướng dẫn sử dụng</span>
              <ChevronIcon />
            </a>
          </div>

          <button
            type="button"
            className="account-menu-row account-menu-logout"
            role="menuitem"
            onClick={() => {
              setOpen(false);
              onSignOut();
            }}
          >
            <span className="account-menu-chip" aria-hidden="true"><LogoutIcon /></span>
            <span>Đăng xuất</span>
          </button>
        </div>
      ) : null}
    </div>
  );
}
