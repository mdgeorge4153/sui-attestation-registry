import { readFileSync } from 'node:fs';
import { normalizeSuiAddress } from '@mysten/sui/utils';

export interface PublishedPackages {
  attestationRegistry: string;
  auditExample: string;
}

/**
 * Parse `Pub.testnet.toml` and return the two package addresses we need.
 * The file is a list of `[[published]]` blocks; we match by source directory.
 */
export function readPubfile(path: string): PublishedPackages {
  const raw = readFileSync(path, 'utf8');
  const blocks = raw.split(/^\[\[published\]\]\s*$/m);

  const find = (sourceDir: string): string => {
    for (const block of blocks) {
      // Sui's test-publish emits `source = { local = "..." }`; tolerate
      // the bare `source = "..."` shape too.
      const sourceMatch =
        block.match(/^\s*source\s*=\s*\{\s*local\s*=\s*"([^"]+)"/m) ??
        block.match(/^\s*source\s*=\s*"([^"]+)"/m);
      const publishedAtMatch = block.match(/^\s*published-at\s*=\s*"([^"]+)"/m);
      if (sourceMatch && publishedAtMatch && sourceMatch[1]!.includes(sourceDir)) {
        return normalizeSuiAddress(publishedAtMatch[1]!);
      }
    }
    throw new Error(`No [[published]] block found for source dir "${sourceDir}" in ${path}`);
  };

  return {
    attestationRegistry: find('attestation_registry'),
    auditExample: find('audit_example'),
  };
}
