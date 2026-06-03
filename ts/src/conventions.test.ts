import test from 'node:test';
import assert from 'node:assert/strict';

import { isEffective, type ConventionsContext } from './conventions.js';
import type { AttestationInfo } from './queries.js';

/** Build a minimal AttestationInfo with just the fields the interpreter reads. */
function att(id: string, display: Record<string, unknown>): AttestationInfo {
  return { id, version: '1', digest: 'd', type: 'Attestation<T>', display };
}

/** A context that resolves `requires` ids against an in-memory map, with a
 *  fixed clock so expiry checks are deterministic. */
function ctxOf(map: Record<string, AttestationInfo>): ConventionsContext {
  return {
    fetchById: async (id: string) => {
      const a = map[id];
      if (!a) throw new Error(`unexpected fetchById(${id})`);
      return a;
    },
    now: () => 1000,
  };
}

test('active with no requires is effective', async () => {
  const a = att('0x1', { active: 'true' });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a })), true);
});

test('inactive (revoked) is ineffective', async () => {
  const a = att('0x1', { active: 'false' });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a })), false);
});

test('expired is ineffective', async () => {
  const a = att('0x1', { active: 'true', expires_at: '500' }); // now=1000 > 500
  assert.equal(await isEffective(a, ctxOf({ '0x1': a })), false);
});

test('requires an active dependency: effective', async () => {
  const dep = att('0x2', { active: 'true' });
  const a = att('0x1', { active: 'true', requires: ['0x2'] });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a, '0x2': dep })), true);
});

test('requires a revoked dependency: ineffective (transitive)', async () => {
  const dep = att('0x2', { active: 'false' });
  const a = att('0x1', { active: 'true', requires: ['0x2'] });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a, '0x2': dep })), false);
});

test('requires rendered as a JSON-array string is parsed', async () => {
  const dep = att('0x2', { active: 'true' });
  const a = att('0x1', { active: 'true', requires: '["0x2"]' });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a, '0x2': dep })), true);
});

test('cyclic requires is ineffective (cycle guard)', async () => {
  const a = att('0x1', { active: 'true', requires: ['0x2'] });
  const b = att('0x2', { active: 'true', requires: ['0x1'] });
  assert.equal(await isEffective(a, ctxOf({ '0x1': a, '0x2': b })), false);
});
