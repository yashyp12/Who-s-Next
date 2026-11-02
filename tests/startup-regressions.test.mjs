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
test('sidebar collapse and expand use smooth desktop and mobile transitions',()=>{
 assert.match(app,/id="sidebar-toggle" type="button" aria-expanded=/);
 assert.match(styles,/transition:grid-template-columns \.28s/);
 assert.match(styles,/max-height \.25s ease/);
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
  assert.match(migration, /last_seen_at > now\(\) - interval '90 seconds'/);
});
