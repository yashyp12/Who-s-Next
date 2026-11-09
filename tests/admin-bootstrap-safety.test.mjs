import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/202611090018_restore_workspace_owner_admin_access.sql', import.meta.url),
  'utf8',
);

test('restores the known workspace owner admin mapping idempotently', () => {
  assert.match(migration, /insert into public\.workspace_admins\s*\(workspace_id, member_id\)/i);
  assert.match(migration, /lower\(trim\(m\.name\)\) = 'yash patil'/i);
  assert.match(migration, /lower\(trim\(w\.name\)\) = 'operations team'/i);
  assert.match(migration, /on conflict\s*\(workspace_id, member_id\) do nothing/i);
});

test('admin restoration does not delete or replace any existing role or user data', () => {
  assert.doesNotMatch(migration, /\b(delete from|truncate|drop table|update public\.)\b/i);
});
