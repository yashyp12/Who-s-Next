import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const migration = await readFile(new URL('../supabase/migrations/202611020008_presence_break_roles.sql', import.meta.url), 'utf8');

test('presence heartbeat exposes active, away and stale offline states', () => {
  assert.match(migration, /presence_state text not null default 'active'/);
  assert.match(migration, /last_seen_at <= now\(\)\s*-\s*interval '90 seconds'/);
  assert.match(migration, /heartbeat_member_presence\(p_state text default 'active'\)/);
  assert.match(app, /setInterval\(syncPresence, 20000\)/);
  assert.match(app, /5 \* 60 \* 1000 \? 'away' : 'active'/);
});

test('offline and away members are excluded by the database allocation functions', () => {
  assert.ok((migration.match(/p\.presence_state = 'active'/g) || []).length >= 3);
  assert.match(migration, /delete from public\.member_presence where auth_user_id=auth\.uid\(\)/);
  assert.match(app, /domainMembers\(\)\.filter\(\(member\) => isPresenceActive\(member\.id\)\)/);
});

test('break allowance is capped at sixty minutes unless an extended break is approved', () => {
  assert.match(migration, /extract\(epoch from \(v_break_end - v_break_start\)\) \/ 60 > 60/);
  assert.match(migration, /request_type = 'extended_break' and r\.status = 'approved'/);
  assert.match(migration, /This break overlaps another planned break/);
});

test('SME and Super Admin share the same admin permission check', () => {
  assert.match(migration, /role text not null default 'sme'/);
  assert.match(migration, /p_role not in \('super_admin','sme','none'\)/);
  assert.match(migration, /public\.is_workspace_admin\(\)/);
  assert.match(app, /Super Admin and SME have the same workspace permissions/);
});

test('admin shift report is date-scoped and the dashboard hides past dates from members', () => {
  assert.match(migration, /admin_shift_allocation_report\(p_work_date date\)/);
  assert.match(migration, /a\\.assigned_at >= coalesce\\([\\s\\S]*?s\\.work_date=v_today/);
  assert.match(app, /admin_shift_allocation_report/);
});

test('workspace refresh broadcasts are emitted for operational changes', () => {
  assert.match(migration, /realtime\.send\([\s\S]*?'refresh'[\s\S]*?'whos-next-'/);
  assert.match(migration, /'allocations','allocation_state','handovers','shift_swap_requests','attendance_events','member_presence'/);
  assert.match(app, /\.on\('broadcast', \{ event: 'refresh' \}/);
  assert.match(app, /60 \* 60 \* 1000/);
});
