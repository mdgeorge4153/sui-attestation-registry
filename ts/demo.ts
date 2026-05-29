/**
 * End-to-end CLI demo against a localnet (or any RPC):
 *   - create Boxes for two real published subjects: `dependency_example` and
 *     `subject_example` (which depends on it)
 *   - audit the dependency (Attestation<Audit>, v1 schema)
 *   - audit the subject with AuditV2 (the upgrade-added schema) that `requires`
 *     the dependency's audit, plus a Vulnerability attestation
 *   - list + pretty-print the attestations with their Display rendering
 *   - evaluate the subject audit's *effectiveness* (transitive `requires`)
 *   - revoke the dependency's audit, and show the subject audit flip to
 *     ineffective
 *   - write `demo-ids.json` (registry id, subjects, trusted attesters) for the
 *     MVR Postgres seeder
 *
 * Run with:
 *   REGISTRY_ID=0x... pnpm demo [--rpc <url>] [--pubfile <path>]
 *
 * Defaults:
 *   - --rpc      http://127.0.0.1:9000 (a `sui start --with-faucet` localnet)
 *   - --pubfile  Pub.localnet.toml at the repo root
 *
 * Requires:
 *   - All packages test-published + audit_example upgraded via
 *     `scripts/test-publish.sh`, which writes the pubfile and prints REGISTRY_ID.
 *   - The sui CLI's keystore at `~/.sui/sui_config/sui.keystore`, with the
 *     active address funded on the target network.
 */

import { writeFileSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { fromBase64, normalizeSuiAddress } from '@mysten/sui/utils';

import {
  makeClient,
  readPubfile,
  boxAddress,
  createBoxTx,
  attestAuditTx,
  attestAuditV2Tx,
  auditAttestationType,
  auditV2AttestationType,
  revokeTx,
  listAttestations,
  getAttestation,
  isEffective,
  type AttestationInfo,
  type PublishedPackages,
} from './lib/index.js';

const KEYSTORE_PATH = join(homedir(), '.sui', 'sui_config', 'sui.keystore');
const DEFAULT_PUBFILE_PATH = join(import.meta.dirname, '..', 'Pub.localnet.toml');
const DEMO_IDS_PATH = join(import.meta.dirname, '..', 'demo-ids.json');
const DEFAULT_RPC = 'http://127.0.0.1:9000';

function loadKeypair(): Ed25519Keypair {
  const raw = readFileSync(KEYSTORE_PATH, 'utf8');
  const keys: unknown = JSON.parse(raw);
  if (!Array.isArray(keys) || keys.length === 0 || typeof keys[0] !== 'string') {
    throw new Error(`unexpected keystore shape at ${KEYSTORE_PATH}`);
  }
  // Each entry: base64(flag-byte || 32-byte secret). Flag 0x00 == Ed25519.
  const decoded = fromBase64(keys[0]);
  if (decoded.length !== 33) {
    throw new Error(`expected 33-byte keystore entry (flag + key), got ${decoded.length}`);
  }
  if (decoded[0] !== 0) {
    throw new Error(`first keystore entry isn't Ed25519 (flag=${decoded[0]}); demo doesn't support others`);
  }
  return Ed25519Keypair.fromSecretKey(decoded.slice(1));
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`env var ${name} is required (see demo.ts docstring)`);
  return normalizeSuiAddress(v);
}

function printAttestation(att: AttestationInfo): void {
  console.log(`  id:      ${att.id}`);
  console.log(`  type:    ${att.type}`);
  if (att.display) {
    console.log('  display:');
    for (const [k, v] of Object.entries(att.display)) {
      console.log(`    ${k}: ${JSON.stringify(v)}`);
    }
  }
}

interface TxOk {
  digest: string;
  createdByType: Map<string, string[]>;
  createdRefs: Map<string, { objectId: string; version: string; digest: string }>;
}

async function exec(
  client: ReturnType<typeof makeClient>,
  signer: Ed25519Keypair,
  tx: Transaction,
): Promise<TxOk> {
  // sui-fork doesn't implement SimulateTransaction yet, which the SDK
  // would otherwise call to compute the gas budget. Set it explicitly so
  // build skips simulation.
  tx.setGasBudget(100_000_000n);
  const res = await client.signAndExecuteTransaction({
    signer,
    transaction: tx,
    include: { effects: true, objectTypes: true },
  });
  if (res.$kind !== 'Transaction') {
    throw new Error(`tx failed: ${JSON.stringify(res, null, 2)}`);
  }
  const t = res.Transaction;
  const status = t.status as { success: boolean; error: unknown };
  if (!status.success) {
    throw new Error(`tx ${t.digest} failed: ${JSON.stringify(t.status)}`);
  }
  // Wait for the tx to be visible across replicas before the next call
  // simulates against a snapshot that might not yet include it.
  await client.waitForTransaction({ digest: t.digest });
  const effects = t.effects;
  const objectTypes = t.objectTypes ?? {};
  const createdByType = new Map<string, string[]>();
  const createdRefs = new Map<string, { objectId: string; version: string; digest: string }>();
  for (const c of effects?.changedObjects ?? []) {
    if (c.idOperation !== 'Created') continue;
    const type = objectTypes[c.objectId];
    if (type !== undefined) {
      const arr = createdByType.get(type) ?? [];
      arr.push(c.objectId);
      createdByType.set(type, arr);
    }
    if (c.outputVersion !== null && c.outputDigest !== null) {
      createdRefs.set(c.objectId, {
        objectId: c.objectId,
        version: c.outputVersion,
        digest: c.outputDigest,
      });
    }
  }
  return { digest: t.digest, createdByType, createdRefs };
}

/** The single created object of `type`, or throw if not exactly one. */
function oneOf(ok: TxOk, type: string, label: string): string {
  const ids = ok.createdByType.get(type) ?? [];
  if (ids.length !== 1) {
    throw new Error(`expected exactly 1 ${label}, got ${ids.length} (type ${type})`);
  }
  return ids[0]!;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      rpc: { type: 'string' },
      pubfile: { type: 'string' },
    },
  });

  const client = makeClient(values.rpc ?? DEFAULT_RPC);
  const signer = loadKeypair();
  const sender = signer.toSuiAddress();
  const pkgs: PublishedPackages = readPubfile(values.pubfile ?? DEFAULT_PUBFILE_PATH);
  const registryId = requireEnv('REGISTRY_ID');

  // The two subjects: the dependency, and the package that depends on it.
  const dependency = pkgs.dependencyExample;
  const subject = pkgs.subjectExample;
  const dependencyBox = boxAddress(registryId, dependency);
  const subjectBox = boxAddress(registryId, subject);

  // Audit (v1) types use audit_example's ORIGINAL id; AuditV2 uses the v2 id.
  const auditType = auditAttestationType({
    attestationRegistryPkg: pkgs.attestationRegistry,
    auditExamplePkg: pkgs.auditExampleOriginal,
  });
  const auditCapType = `${pkgs.attestationRegistry}::attestation_registry::RevocationCap<${pkgs.auditExampleOriginal}::audit::Audit>`;
  const auditV2Type = auditV2AttestationType({
    attestationRegistryPkg: pkgs.attestationRegistry,
    auditExamplePkg: pkgs.auditExample,
  });

  console.log(`sender:          ${sender}`);
  console.log(`registry:        ${registryId}`);
  console.log(`dependency:      ${dependency}`);
  console.log(`  box:           ${dependencyBox}`);
  console.log(`subject:         ${subject}`);
  console.log(`  box:           ${subjectBox}`);

  console.log('\n▶ TX 1 — create_box for dependency and subject');
  {
    const tx = new Transaction();
    createBoxTx(tx, { attestationRegistryPkg: pkgs.attestationRegistry, registryId, subject: dependency });
    createBoxTx(tx, { attestationRegistryPkg: pkgs.attestationRegistry, registryId, subject });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ TX 2 — attest_audit on dependency (score=90, will be revoked)');
  let depAuditId: string;
  let depAuditRef: { objectId: string; version: string; digest: string };
  let depAuditCap: string;
  {
    const tx = new Transaction();
    const cap = attestAuditTx(tx, { auditExamplePkg: pkgs.auditExample, registryId, subject: dependency, score: 90, reportUrl: 'https://audits.example.com/dependency-v1.pdf' });
    tx.transferObjects([cap], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    depAuditId = oneOf(ok, auditType, 'Attestation<Audit>');
    depAuditCap = oneOf(ok, auditCapType, 'RevocationCap<Audit>');
    depAuditRef = ok.createdRefs.get(depAuditId)!;
  }

  console.log('\n▶ TX 2b — attest_vuln on dependency (effective; should propagate to subject)');
  {
    const tx = new Transaction();
    const [cap] = tx.moveCall({
      target: `${pkgs.vulnExample}::vuln::attest_vuln`,
      arguments: [
        tx.object(registryId),
        tx.pure.id(dependency),
        tx.pure.u8(7),
        tx.pure.string('CVE-2026-0042'),
        tx.pure.string('Heap overflow in the dependency'),
        tx.pure.string('https://scanner.example.com/CVE-2026-0042'),
      ],
    });
    tx.transferObjects([cap!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ TX 3 — attest_audit_v2 on subject (score=95, requires dependency audit)');
  let subjectAuditId: string;
  {
    const tx = new Transaction();
    const cap = attestAuditV2Tx(tx, {
      auditExamplePkg: pkgs.auditExample,
      registryId,
      subject,
      score: 95,
      reportUrl: 'https://audits.example.com/subject-v1.pdf',
      requires: [depAuditId],
    });
    tx.transferObjects([cap], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    subjectAuditId = oneOf(ok, auditV2Type, 'Attestation<AuditV2>');
  }

  console.log('\n▶ TX 3b — attest_audit on subject (score=88, stays effective)');
  {
    const tx = new Transaction();
    const cap = attestAuditTx(tx, { auditExamplePkg: pkgs.auditExample, registryId, subject, score: 88, reportUrl: 'https://audits.example.com/subject-v1.pdf' });
    tx.transferObjects([cap], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ TX 4 — attest_vuln on subject (severity=4)');
  let subjectVulnId: string;
  {
    const tx = new Transaction();
    const [cap] = tx.moveCall({
      target: `${pkgs.vulnExample}::vuln::attest_vuln`,
      arguments: [
        tx.object(registryId),
        tx.pure.id(subject),
        tx.pure.u8(4),
        tx.pure.string('CVE-2026-0001'),
        tx.pure.string('Example informational finding'),
        tx.pure.string('https://scanner.example.com/CVE-2026-0001'),
      ],
    });
    tx.transferObjects([cap!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    const vulnType = `${pkgs.attestationRegistry}::attestation_registry::Attestation<${pkgs.vulnExample}::vuln::Vulnerability>`;
    subjectVulnId = oneOf(ok, vulnType, 'Attestation<Vulnerability>');
  }

  // Negative test data: two attestations a trust consumer must filter out — one
  // from an untrusted attester (filtered on the package), one of a trusted
  // package's type with no registered Display (filtered on the Display-gate).
  console.log('\n▶ TX 5 — attest_untrusted + attest_internal_note (both should be filtered out)');
  {
    const tx = new Transaction();
    const [u] = tx.moveCall({
      target: `${pkgs.untrustedExample}::untrusted::attest_untrusted`,
      arguments: [tx.object(registryId), tx.pure.id(subject), tx.pure.string('not whitelisted')],
    });
    const [n] = tx.moveCall({
      target: `${pkgs.auditExample}::audit_v2::attest_internal_note`,
      arguments: [tx.object(registryId), tx.pure.id(subject), tx.pure.string('no Display registered')],
    });
    tx.transferObjects([u!, n!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ Read — all attestations on subject');
  for (const att of await listAttestations(client, subjectBox, { includeDisplay: true })) {
    console.log('');
    printAttestation(att);
  }

  // Effectiveness honours the transitive `requires` convention: the subject
  // audit is only effective while the dependency audit it requires is.
  const ctx = { fetchById: (id: string) => getAttestation(client, id, { includeDisplay: true }) };
  const reportEffective = async (label: string) => {
    const root = await getAttestation(client, subjectAuditId, { includeDisplay: true });
    console.log(`\n▶ ${label}: subject AuditV2 effective = ${await isEffective(root, ctx)}`);
  };

  await reportEffective('Before revoke');

  console.log('\n▶ TX 6 — revoke the dependency audit');
  {
    const tx = new Transaction();
    revokeTx(tx, {
      attestationRegistryPkg: pkgs.attestationRegistry,
      boxId: dependencyBox,
      capId: depAuditCap,
      attestationRef: depAuditRef,
      attestationType: `${pkgs.auditExampleOriginal}::audit::Audit`,
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  await reportEffective('After revoke');

  // Hand-off for the MVR Postgres seeder.
  const demoIds = {
    registryId,
    attestationRegistryPkg: pkgs.attestationRegistry,
    subjects: { subject, dependency },
    trustedAttestors: [
      { name: 'audit_example', originalId: pkgs.auditExampleOriginal, latestId: pkgs.auditExample },
      { name: 'vuln_example', originalId: pkgs.vulnExample, latestId: pkgs.vulnExample },
    ],
    createdAttestations: {
      dependencyAudit: depAuditId,
      subjectAuditV2: subjectAuditId,
      subjectVuln: subjectVulnId,
    },
  };
  writeFileSync(DEMO_IDS_PATH, JSON.stringify(demoIds, null, 2) + '\n');
  console.log(`\n▶ wrote ${DEMO_IDS_PATH}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
