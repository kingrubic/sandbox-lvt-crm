import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const iosRoot = readFileSync(new URL('../ios-uikit-lvt/LvtCrmUIKit/RootTabBarController.swift', import.meta.url), 'utf8');
const iosCluster = readFileSync(new URL('../ios-uikit-lvt/LvtCrmUIKit/AccountHeaderCluster.swift', import.meta.url), 'utf8');
const iosModels = readFileSync(new URL('../ios-uikit-lvt/LvtCrmUIKit/NotificationModels.swift', import.meta.url), 'utf8');
const iosChangelog = readFileSync(new URL('../ios-uikit-lvt/LvtCrmUIKit/AppChangelog.swift', import.meta.url), 'utf8');
const androidRoot = readFileSync(new URL('../android-app/app/src/main/java/lvt/crm/ui/LvtRoot.kt', import.meta.url), 'utf8');
const androidHeader = readFileSync(new URL('../android-app/app/src/main/java/lvt/crm/ui/components/AccountHeader.kt', import.meta.url), 'utf8');
const androidScreen = readFileSync(new URL('../android-app/app/src/main/java/lvt/crm/ui/components/LvtComponents.kt', import.meta.url), 'utf8');
const androidChangelog = readFileSync(new URL('../android-app/app/src/main/java/lvt/crm/ui/profile/AppChangelog.kt', import.meta.url), 'utf8');

test('iOS bottom bar is Tổng quan, Trao đổi, Lịch CT and Công việc', () => {
  assert.match(iosRoot, /viewControllers = \[overview, chat, duties, work\]/);
  assert.match(iosRoot, /title: "Trao đổi"/);
  assert.doesNotMatch(iosRoot, /title: "Thông báo"/);
  assert.doesNotMatch(iosRoot, /title: "Cá nhân"/);
  assert.match(iosModels, /case overview/);
  assert.match(iosModels, /case chat/);
  assert.doesNotMatch(iosModels, /case notifications/);
  assert.doesNotMatch(iosModels, /case profile/);
});

test('iOS header cluster opens notifications and profile from the trailing pill', () => {
  assert.match(iosRoot, /makeAccountHeaderItem\(\)/);
  assert.match(iosRoot, /openNotifications\(\)/);
  assert.match(iosRoot, /openProfile\(\)/);
  assert.match(iosRoot, /cluster\.onBell/);
  assert.match(iosRoot, /cluster\.onAvatar/);
  assert.match(iosCluster, /AccountHeaderClusterView/);
  assert.match(iosCluster, /func accountInitials/);
  assert.match(iosCluster, /func unreadBadgeText/);
  assert.match(iosRoot, /updateHeaderClusters\(\)/);
});

test('iOS push destinations still route to Lịch CT or Công việc', () => {
  assert.match(iosModels, /kind == "duty" \? \.duties : \.work/);
  assert.match(iosRoot, /func route\(_ destination: NotificationDestination/);
  assert.match(iosRoot, /tabControllers\[tab\]/);
});

test('iOS changelog still records the 1.9.0 header cluster', () => {
  assert.match(iosChangelog, /version: "1\.9\.0"/);
  assert.match(iosChangelog, /chuông \+ ảnh đại diện/);
  assert.match(iosChangelog, /Đổi ảnh đại diện/);
});

test('Android bottom bar is Tổng quan, (Lớp chủ nhiệm), Trao đổi, Lịch CT and Công việc', () => {
  assert.match(androidRoot, /Routes\.Overview, R\.string\.nav_overview/);
  assert.match(androidRoot, /if \(canSeeHomeroom\) add\(Triple\(Routes\.Homeroom, R\.string\.nav_homeroom/);
  assert.match(androidRoot, /Routes\.Chat, R\.string\.nav_chat/);
  assert.match(androidRoot, /Routes\.Duties, R\.string\.nav_duties/);
  assert.match(androidRoot, /Routes\.Work, R\.string\.nav_work/);
  assert.doesNotMatch(androidRoot, /Routes\.Notifications, R\.string\.nav_notifications/);
  assert.doesNotMatch(androidRoot, /Routes\.Profile, R\.string\.nav_profile/);
  assert.match(androidRoot, /mainTabRoutes = tabs\.mapTo\(mutableSetOf\(\)\) \{ it\.first \}/);
});

test('Android header cluster sits in the top app bar and reuses unread count', () => {
  assert.match(androidRoot, /AccountHeaderState\(/);
  assert.match(androidRoot, /onOpenNotifications = \{ openNotifications\(\) \}/);
  assert.match(androidRoot, /onOpenProfile = \{ openProfile\(\) \}/);
  assert.match(androidRoot, /LocalAccountHeader provides accountHeader/);
  assert.match(androidScreen, /showAccountHeader: Boolean = false/);
  assert.match(androidScreen, /AccountHeaderCluster\(accountHeader\)/);
  assert.match(androidHeader, /fun accountInitials/);
  assert.match(androidHeader, /fun unreadBadgeText/);
  assert.match(androidRoot, /unreadCount = notificationState\.unreadCount/);
});

test('Android notification destinations still navigate to duties or work', () => {
  assert.match(androidRoot, /navController\.navigate\(destination\.route\)/);
  assert.match(androidRoot, /composable\(Routes\.Notifications\)/);
  assert.match(androidRoot, /composable\(Routes\.Profile\)/);
});

test('Android changelog still records the 0.17.0 header cluster', () => {
  assert.match(androidChangelog, /"0\.17\.0"/);
  assert.match(androidChangelog, /chuông \+ ảnh đại diện/);
  assert.match(androidChangelog, /Đổi ảnh đại diện/);
});
