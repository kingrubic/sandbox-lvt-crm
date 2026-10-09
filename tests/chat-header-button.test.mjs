import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { isSidebarPrimaryMenu, pathnameForMenu } from '../src/navigationRoutes.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const mainSource = readFileSync(join(root, 'src/main.jsx'), 'utf8');
const routesSource = readFileSync(join(root, 'src/navigationRoutes.js'), 'utf8');
const cssSource = readFileSync(join(root, 'src/notifications/notifications.css'), 'utf8');

test('Trao đổi is a header control, not a sidebar primary menu', () => {
  assert.equal(pathnameForMenu('chat'), '/trao-doi');
  assert.equal(isSidebarPrimaryMenu('chat'), false);
  assert.match(routesSource, /SIDEBAR_HIDDEN_MENUS = Object\.freeze\(\['notifications', 'chat'\]\)/);
  assert.match(mainSource, /function ChatHeaderButton/);
  assert.match(mainSource, /canUseChat \? \(/);
  assert.match(mainSource, /header-chat-button/);
  assert.match(mainSource, /onClick=\{\(\) => choose\('chat'\)\}/);
  assert.match(mainSource, /unreadCount=\{chatUnread\?\.count \|\| 0\}/);
  // Chat button sits immediately before the notification bell in the header cluster.
  const headerUser = mainSource.split('className="header-user"')[1]?.split('</div>')[0] || '';
  assert.match(headerUser, /ChatHeaderButton/);
  assert.match(headerUser, /NotificationBell/);
  assert.ok(headerUser.indexOf('ChatHeaderButton') < headerUser.indexOf('NotificationBell'));
});

test('header chat button reuses explicit bell colors (not white-on-white)', () => {
  assert.match(cssSource, /\.header-chat-button\s*\{/);
  assert.match(cssSource, /color:\s*#27567a/);
  assert.match(cssSource, /background:\s*#f8fbfc/);
  assert.match(cssSource, /\.header-chat-button\.is-active/);
  assert.match(cssSource, /\.header-chat-badge/);
});
