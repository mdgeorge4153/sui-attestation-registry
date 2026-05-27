/**
 * Off-chain evaluator for the Display-field conventions documented in
 * CONVENTIONS.md at the repo root.
 *
 * An attestation is *effective* iff:
 *   1. its on-chain `active` field is true, AND
 *   2. its `expires_at` Display field (if present) is in the future, AND
 *   3. every attestation referenced via its `requires` Display field
 *      (if present) is itself effective (transitive).
 *
 * Cycles in the `requires` graph are treated as ineffective.
 */

import type { AttestationInfo } from './queries.js';

export interface ConventionsContext {
  /** Fetch an attestation by id. Required for `requires` traversal. */
  fetchById: (id: string) => Promise<AttestationInfo>;
  /** Current Unix-ms. Default: `Date.now()`. */
  now?: () => number;
}

export async function isEffective(
  attestation: AttestationInfo,
  ctx: ConventionsContext,
  visited: Set<string> = new Set(),
): Promise<boolean> {
  if (!readActive(attestation)) return false;

  const expiresAt = readExpiresAt(attestation);
  const now = (ctx.now ?? Date.now)();
  if (expiresAt !== null && now >= expiresAt) return false;

  const required = readRequires(attestation);
  if (required.length > 0) {
    if (visited.has(attestation.id)) return false; // cycle
    const next = new Set(visited);
    next.add(attestation.id);
    for (const reqId of required) {
      const req = await ctx.fetchById(reqId);
      if (!(await isEffective(req, ctx, next))) return false;
    }
  }

  return true;
}

/**
 * The registry's `register_display` auto-appends `active => {active}`, which
 * renders as `"true"` or `"false"`. Accept either the string or the parsed
 * boolean depending on how the consumer surfaced the display object.
 */
function readActive(att: AttestationInfo): boolean {
  const raw = att.display?.['active'];
  if (raw === true || raw === 'true') return true;
  if (raw === false || raw === 'false') return false;
  // If active isn't in display, default to true so the conventions still
  // apply on top of an as-yet-unaugmented attestation. A schema that wants
  // strict checking should ensure `active` is in its Display template.
  return true;
}

/**
 * The `expires_at` convention renders a timestamp. Schemas typically use the
 * `:ts` Display transform on a `u64` field, which produces an ISO 8601
 * string. Falls back to numeric parsing for schemas that surface the raw
 * milliseconds.
 */
function readExpiresAt(att: AttestationInfo): number | null {
  const raw = att.display?.['expires_at'];
  if (raw == null) return null;
  if (typeof raw === 'number') return raw;
  if (typeof raw === 'string') {
    const asNum = Number(raw);
    if (!Number.isNaN(asNum) && asNum > 0) return asNum;
    const asDate = Date.parse(raw);
    if (!Number.isNaN(asDate)) return asDate;
  }
  return null;
}

/**
 * The `requires` convention renders a list of attestation object IDs.
 * Schemas should use the `:json` transform to surface the field as a
 * structured array; for now we accept either an array or a JSON-string.
 */
function readRequires(att: AttestationInfo): string[] {
  const raw = att.display?.['requires'];
  if (raw == null) return [];
  if (Array.isArray(raw)) return raw.filter((x): x is string => typeof x === 'string');
  if (typeof raw === 'string') {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        return parsed.filter((x): x is string => typeof x === 'string');
      }
    } catch {
      // not JSON; ignore
    }
  }
  return [];
}
