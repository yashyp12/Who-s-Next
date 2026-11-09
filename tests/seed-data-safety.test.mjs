import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const seed = await readFile(new URL('../supabase/seed.sql', import.meta.url), 'utf8');

test('re-running the seed never overwrites an existing member access code', () => {
  const accessCodeSeed = seed.slice(seed.indexOf('insert into public.member_access_codes'));
  assert.match(accessCodeSeed, /on conflict \(member_id\) do nothing/);
  assert.doesNotMatch(accessCodeSeed, /do update\s+set access_code_hash/i);
});

test('seed setup keeps existing workspace and member rows on conflict', () => {
  assert.match(seed, /on conflict \(id\) do nothing/);
  assert.match(seed, /on conflict \(workspace_id, sort_order\) do nothing/);
  assert.match(seed, /on conflict \(workspace_id\) do nothing/);
});
