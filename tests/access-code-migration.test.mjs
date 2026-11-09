import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/202611090017_preserve_legacy_access_code_compatibility.sql', import.meta.url),
  'utf8',
);

const sha256 = (value) => createHash('sha256').update(value, 'utf8').digest('hex');

test('access-code login accepts both normalized and legacy case-sensitive hashes', () => {
  const entered = 'Yashyp12';
  const normalizedHash = sha256(entered.trim().toLowerCase());
  const legacyHash = sha256(entered.trim());

  assert.notEqual(normalizedHash, legacyHash);
  assert.match(migration, /encode\(extensions\.digest\(v_normalized_code, 'sha256'\), 'hex'\)/);
  assert.match(migration, /encode\(extensions\.digest\(v_raw_code, 'sha256'\), 'hex'\)/);
  assert.match(migration, /access_code_hash in \([\s\S]*?v_normalized_code[\s\S]*?v_raw_code/);
});

test('short admin-managed access codes remain supported by the database RPC', () => {
  assert.match(migration, /length\(v_raw_code\) < 8/);
  assert.match(migration, /length\(v_raw_code\) > 200/);
  assert.match(migration, /v_raw_code !~ '\^\[A-Za-z0-9\._-\]\+\$'/);
});

test('access-code compatibility migration preserves all existing workspace data', () => {
  assert.match(migration, /create or replace function public\.join_workspace/);
  assert.doesNotMatch(migration, /\b(delete from|truncate|drop table|drop schema)\b/i);
  assert.doesNotMatch(migration, /insert into public\.(workspaces|members|member_access_codes)/i);
  assert.match(migration, /on conflict \(auth_user_id\) do update/);
  assert.match(migration, /grant execute on function public\.join_workspace\(text\) to authenticated/);
});
