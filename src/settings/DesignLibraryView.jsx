import React, { useEffect, useState } from 'react';
import { useConvexAuth } from '@convex-dev/auth/react';
import {
  DESIGN_LIBRARY_URL,
  designLibraryErrorMessage,
  prepareDesignLibraryDocument,
} from './designLibrary.js';
import './designLibrary.css';

export default function DesignLibraryView() {
  const { fetchAccessToken } = useConvexAuth();
  const [state, setState] = useState({ status: 'loading', html: '', error: '' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const token = await fetchAccessToken({ forceRefreshToken: false });
        if (!token) throw Object.assign(new Error('UNAUTHORIZED'), { status: 401 });
        const response = await fetch(DESIGN_LIBRARY_URL, {
          headers: { Authorization: `Bearer ${token}` },
          cache: 'no-store',
        });
        if (!response.ok) throw Object.assign(new Error('DESIGN_LIBRARY_FAILED'), { status: response.status });
        const html = prepareDesignLibraryDocument(await response.text());
        if (!cancelled) setState({ status: 'ready', html, error: '' });
      } catch (error) {
        if (!cancelled) setState({ status: 'error', html: '', error: designLibraryErrorMessage(error?.status) });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [fetchAccessToken]);

  if (state.status === 'loading') {
    return <section className="design-library-view"><div className="design-library-state">Đang tải Thư viện giao diện…</div></section>;
  }
  if (state.status === 'error') {
    return <section className="design-library-view"><div className="design-library-state is-error">{state.error}</div></section>;
  }
  return (
    <section className="design-library-view">
      <p className="design-library-note">
        Bản prototype gốc — chỉ Administrator xem được. Quy chuẩn đang áp dụng nằm trong <code>DESIGN.md</code>.
      </p>
      <iframe
        className="design-library-frame"
        title="Thư viện giao diện"
        sandbox="allow-scripts"
        referrerPolicy="no-referrer"
        srcDoc={state.html}
      />
    </section>
  );
}
