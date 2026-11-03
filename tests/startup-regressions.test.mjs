import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');
const styles = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const migration = await readFile(new URL('../supabase/migrations/202611020009_fix_workspace_refresh_trigger.sql', import.meta.url), 'utf8');

test('optional admin role controls use a collection selector before forEach', () => {
  assert.match(app, /\$\$\('\[data-admin-role-save\]'\)\.forEach/);
  assert.equal(app.split('\n').some((line) => line.trimStart().startsWith("$('[data-admin-role-save]')")), false);
});

test('workspace refresh trigger safely checks presence fields only through row JSON', () => {
  assert.match(migration, /if tg_table_name = 'member_presence' then\s+if tg_op = 'UPDATE' then/);
  assert.match(migration, /to_jsonb\(new\)->>'presence_state'/);
  assert.match(migration, /to_jsonb\(old\)->>'presence_state'/);
  assert.doesNotMatch(migration, /new\.presence_state|old\.presence_state/);
});

test('startup loader uses the WHO\'S next mark and animated progress treatment', () => {
  assert.match(html, /class="loader-emblem"/);
  assert.match(html, /class="loader-mark">W/);
  assert.match(html, /class="loader-progress"/);
  assert.match(styles, /@keyframes loader-mark-pulse/);
  assert.match(styles, /@keyframes loader-progress/);
});

test('access-code submission shows a spinner and restores the button after failure', () => {
  assert.match(app, /button\.setAttribute\('aria-busy', 'true'\)/);
  assert.match(app, /class="button-spinner"/);
  assert.match(app, /button\.removeAttribute\('aria-busy'\)/);
});


test('workspace header centers the timer and orders top actions', () => {
 const header=app.slice(app.indexOf('<header class="topbar">'),app.indexOf('</header>'));
 assert.ok(header.indexOf('id="workspace-clock"')>header.indexOf('topbar-title-wrap'));
 assert.ok(header.indexOf('id="new-request-top"')<header.indexOf('id="refresh-workspace"'));
 assert.ok(header.indexOf('id="refresh-workspace"')<header.indexOf('class="notification-center"'));
 assert.ok(header.indexOf('class="notification-center"')<header.indexOf('class="live-pill"'));
 assert.match(styles,/position:absolute;left:50%;transform:translateX\(-50%\)/);
});
test('workspace sidebar stays open without collapse controls', () => {
 assert.match(app, /const sidebarCollapsed = false/);
 assert.doesNotMatch(app, /id="sidebar-toggle"/);
 assert.doesNotMatch(app, /function toggleSidebar\(/);
 assert.match(styles, /\.layout\.sidebar-collapsed > \.sidebar \{ display: flex !important; \}/);
});


test('My profile exposes edit and withdraw controls only for own availability requests', () => {
  assert.match(app, /function renderOwnAvailabilityRequestCard\(request\)/);
  assert.match(app, /data-edit-own-request=/);
  assert.match(app, /data-withdraw-request=/);
  assert.match(app, /request\.memberId === currentMemberId/);
  assert.match(app, /update_my_availability_request/);
  assert.match(app, /withdraw_my_availability_request/);
});

test('takeover verifies the persisted assignee after server reconciliation', () => {
  assert.match(app, /await reloadRemote\(\);\s+if \(!isCurrentAssignee\(\)\) throw new Error/);
  assert.match(app, /Withdraw any active approved unavailability request from My profile/);
});

test('request withdrawal migration restricts updates to the authenticated request owner', async () => {
  const migration = await readFile(new URL('../supabase/migrations/202611020010_request_withdrawal_and_takeover_guard.sql', import.meta.url), 'utf8');
  assert.match(migration, /status in \('pending','approved','rejected','cancelled'\)/);
  assert.match(migration, /v_request\.member_id is distinct from v_member_id/);
  assert.match(migration, /create or replace function public\.withdraw_my_availability_request/);
  assert.match(migration, /create or replace function public\.update_my_availability_request/);
  assert.match(migration, /create or replace function public\.take_over_allocation/);
  assert.match(migration, /presence_state = 'active'/);
  assert.match(migration, /last_seen_at > v_now - interval '90 seconds'/);
});


test('logout performs atomic server-side handover to the next eligible colleague in the same shift', async () => {
  const migration = await readFile(new URL('../supabase/migrations/202611020011_atomic_logout_handover.sql', import.meta.url), 'utf8');
  const offlineFunction = migration.slice(
    migration.indexOf('create or replace function public.set_member_offline()'),
    migration.indexOf('revoke execute on function public.ensure_shift_assignee()')
  );
  const reconciliation = migration.slice(
    migration.indexOf('create or replace function public.ensure_shift_assignee()'),
    migration.indexOf('-- Deleting presence and reconciling ownership')
  );

  assert.match(offlineFunction, /delete from public\.member_presence[\s\S]*?v_handover := public\.ensure_shift_assignee\(\)/);
  assert.match(offlineFunction, /'handover', v_handover/);
  assert.match(reconciliation, /for update/);
  assert.match(reconciliation, /last_seen_at > v_now - interval '90 seconds'/);
  assert.match(reconciliation, /r\.status = 'approved'[\s\S]*?r\.end_at > v_now/);
  assert.match(reconciliation, /s\.shift_key = v_previous_shift_key/);
  assert.match(reconciliation, /m\.sort_order > coalesce\(v_previous_sort_order/);
  assert.match(reconciliation, /'automatic_handover'/);
  assert.match(reconciliation, /'No eligible colleague is on shift; allocation responsibility is unassigned'/);
});


test('workspace sidebar remains open and no collapse controls are rendered', () => {
  assert.match(app, /const sidebarCollapsed = false/);
  assert.doesNotMatch(app, /id="sidebar-toggle"/);
  assert.doesNotMatch(app, /function toggleSidebar\(/);
  assert.match(styles, /\.layout\.sidebar-collapsed > \.sidebar \{ display: flex !important; \}/);
});

test('workspace clock always renders a fallback and safely handles invalid workspace timezones', () => {
  const clock = app.slice(app.indexOf('function startWorkspaceClock()'), app.indexOf('function addCalendarDays'));
  assert.match(clock, /clock\.textContent = formatWorkspaceClock\(now\)/);
  assert.match(clock, /timeZone: workspaceTimezone[\s\S]*?\} catch \(error\)/);
  assert.match(app, /function formatWorkspaceClock\(now = new Date\(\)\)/);
  assert.match(app, /aria-label="Workspace time">\$\{escapeHtml\(formatWorkspaceClock\(\)\)\}/);
});

test('logout verifies the atomic handover result and never silently signs out on an old database function', () => {
  const signOut = app.slice(app.indexOf('async function signOut()'), app.indexOf('function latestAttendanceForCurrentMember()'));
  assert.match(signOut, /supabase\.rpc\('set_member_offline'\)/);
  assert.doesNotMatch(signOut, /supabase\.rpc\('ensure_shift_assignee'/);
  assert.match(signOut, /offlineResult\?\.handover/);
  assert.match(signOut, /hasOwnProperty\.call\(handover, 'current_assignee_id'\)/);
  assert.match(signOut, /handover\.current_assignee_id === currentMemberId/);
  assert.match(signOut, /heartbeatPresence\('active'\)/);
  assert.doesNotMatch(signOut, /if \(checkoutError\) throw checkoutError/);
});


test('optional request and swap actions use collection selectors and cannot abort page initialization', () => {
  assert.match(app, /\$\$\('\[data-edit-own-request\]'\)\.forEach/);
  assert.match(app, /\$\$\('\[data-withdraw-request\]'\)\.forEach/);
  assert.match(app, /\$\$\('\[data-swap-response\]'\)\.forEach/);
  assert.doesNotMatch(app, /(?<!\$)\$\('\[(?:data-edit-own-request|data-withdraw-request|data-swap-response)\]'\)\.forEach/);
});

test('admin roster loader remains reachable after optional profile controls are bound', () => {
  const render = app.slice(app.indexOf('function renderApp()'), app.indexOf('function startWorkspaceClock()'));
  assert.ok(render.indexOf('bindViewActions();') < render.indexOf('loadAdminRoster();'));
  assert.match(app, /async function loadAdminRoster\(\)/);
  assert.match(app, /supabase\.rpc\('admin_list_members'\)/);
});

test('withdrawal migration locks allocation state before the request row', async () => {
  const migration = await readFile(new URL('../supabase/migrations/202611020012_fix_withdrawal_lock_order.sql', import.meta.url), 'utf8');
  const stateLock = migration.indexOf('from public.allocation_state');
  const requestLock = migration.indexOf('from public.availability_requests');
  assert.ok(stateLock >= 0 && requestLock > stateLock);
  assert.match(migration, /for update[\s\S]*?select \* into v_request/);
  assert.match(migration, /perform public\.ensure_shift_assignee\(\)/);
});

test('responsive header moves to a reserved grid before clock and actions can overlap', () => {
  assert.match(styles, /@media\(max-width:1100px\)\{\s*\.topbar\{display:grid;/);
  assert.match(styles, /\.top-actions \.mobile-profile-toggle\{display:inline-flex/);
});


test('notification delivery retries audio unlock, resumes before playback, and avoids background-screen popups', async () => {
  const notifications = await readFile(new URL('../site/src/notifications.mjs', import.meta.url), 'utf8');
  assert.match(notifications, /document\.addEventListener\('pointerdown', unlockAudio, \{ capture: true, passive: true \}\)/);
  assert.doesNotMatch(notifications, /pointerdown', unlockAudio, \{ once: true/);
  assert.match(notifications, /if \(context\.state === 'suspended'\) await context\.resume\(\)/);
  assert.match(notifications, /document\.visibilityState === 'visible' && document\.hasFocus\(\)/);
  assert.match(notifications, /void playNotificationSound\(\)/);
  assert.match(notifications, /notificationFetchQueued/);
});

test('reading a notification marks it read and closes the inbox', async () => {
  const notifications = await readFile(new URL('../site/src/notifications.mjs', import.meta.url), 'utf8');
  assert.match(notifications, /mark_my_notification_read/);
  assert.match(notifications, /isOpen = false;\s+renderList\(\)/);
});

test('today allocation log is height-constrained and independently scrollable', () => {
  assert.match(styles, /\.allocation-log \{[\s\S]*?max-height: min\(390px, 44vh\);[\s\S]*?overflow-y: auto/);
  assert.match(styles, /\.allocation-log-head \{[\s\S]*?position: sticky;[\s\S]*?top: 0/);
  assert.match(styles, /overscroll-behavior: contain/);
});


test('regular member workspace is scoped to the current day while admins retain historical visibility', () => {
  assert.match(app, /function visibleMemberRequests\(\)/);
  assert.match(app, /function visibleMemberAllocations\(\)/);
  assert.match(app, /currentIsAdmin \? state\.allocations : state\.allocations\.filter/);
  assert.match(app, /const floorDate = addCalendarDays\(localDate\(\), -1\)/);
  assert.match(app, /function shiftForMember\(memberId, date = localDate\(\)\)/);
  assert.match(app, /return overnight && localTime\(\) < overnight\.end \? overnight : null/);
});

test('daily workspace migration scopes member history and reconciles ownership after shift edits', async () => {
  const migration = await readFile(new URL('../supabase/migrations/202611030014_daily_workspace_and_shift_consistency.sql', import.meta.url), 'utf8');
  assert.match(migration, /public\.is_workspace_admin\(\) or \(a\.assigned_at at time zone v_workspace\.timezone\)::date = v_today/);
  assert.match(migration, /status = 'pending' or \(status = 'approved' and end_at > now\(\)\)/);
  assert.match(migration, /perform public\.ensure_shift_assignee\(\)/);
  assert.match(migration, /create or replace function public\.get_dashboard\(\)/);
});

test('notification inbox can be dismissed without reopening the bell and Escape closes it', async () => {
  const notifications = await readFile(new URL('../site/src/notifications.mjs', import.meta.url), 'utf8');
  const styles = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
  assert.match(notifications, /id="notification-close"/);
  assert.match(notifications, /event\.key === 'Escape'/);
  assert.match(notifications, /!root\.contains\(event\.target\)/);
  assert.match(styles, /\.notification-popover-close/);
  assert.match(notifications, /exponentialRampToValueAtTime\(0\.22/);
});


test('access-code login accepts the admin-managed minimum length of eight characters', async () => {
  const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /minlength="8"/);
  assert.match(app, /A-Za-z0-9\\._-/);
  assert.doesNotMatch(app, /code\.length < 16/);
});
