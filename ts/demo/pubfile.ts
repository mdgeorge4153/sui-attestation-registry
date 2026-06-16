import { readFileSync } from 'node:fs';
import { normalizeSuiAddress } from '@mysten/sui/utils';

export interface PublishedPackages {
  attestationRegistry: string;
  /** audit_example's latest `published-at` (v2 after the upgrade). Call
   *  target, and the defining id for `AuditV2`. */
  auditExample: string;
  /** audit_example's `original-id`. The defining id for the v1 `Audit` type,
   *  which keeps the original id across the upgrade. */
  auditExampleOriginal: string;
  subjectExample: string;
  dependencyExample: string;
  untrustedExample: string;
}

interface Ids {
  publishedAt: string;
  originalId: string;
}

/**
 * Parse `Pub.<network>.toml` and return the package addresses the demo needs.
 * The file is a list of `[[published]]` blocks; we match each by source
 * directory and read both `published-at` and `original-id`.
 */
export function readPubfile(path: string): PublishedPackages {
  const raw = readFileSync(path, 'utf8');
  const blocks = raw.split(/^\[\[published\]\]\s*$/m);

  const find = (sourceDir: string): Ids => {
    for (const block of blocks) {
      // Sui's test-publish emits `source = { local = "..." }`; tolerate
      // the bare `source = "..."` shape too.
      const sourceMatch =
        block.match(/^\s*source\s*=\s*\{\s*local\s*=\s*"([^"]+)"/m) ??
        block.match(/^\s*source\s*=\s*"([^"]+)"/m);
      const publishedAtMatch = block.match(/^\s*published-at\s*=\s*"([^"]+)"/m);
      const originalIdMatch = block.match(/^\s*original-id\s*=\s*"([^"]+)"/m);
      if (sourceMatch && publishedAtMatch && sourceMatch[1]!.includes(sourceDir)) {
        const publishedAt = normalizeSuiAddress(publishedAtMatch[1]!);
        return {
          publishedAt,
          // Fall back to published-at if original-id is absent (e.g. a
          // package that was never upgraded on an older toolchain).
          originalId: originalIdMatch
            ? normalizeSuiAddress(originalIdMatch[1]!)
            : publishedAt,
        };
      }
    }
    throw new Error(`No [[published]] block found for source dir "${sourceDir}" in ${path}`);
  };

  const audit = find('audit_example');

  return {
    attestationRegistry: find('attestation_registry').publishedAt,
    auditExample: audit.publishedAt,
    auditExampleOriginal: audit.originalId,
    subjectExample: find('subject_example').publishedAt,
    dependencyExample: find('dependency_example').publishedAt,
    untrustedExample: find('untrusted_example').publishedAt,
  };
}
