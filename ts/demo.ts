/**
 * End-to-end CLI demo against testnet:
 *   - create a Box for a fresh subject
 *   - issue one audit attestation (to be revoked), then one audit (active),
 *     then one vulnerability attestation
 *   - list and pretty-print the attestations with their Display rendering
 *   - revoke the first audit attestation
 *   - re-list to show the active=false transition
 *
 * Run with:
 *   REGISTRY_ID=0x... pnpm demo [--rpc <url>] [--subject <hex-id>]
 *
 * Requires:
 *   - All three packages published to testnet, with addresses recorded in
 *     `Pub.testnet.toml` at the repo root.
 *   - REGISTRY_ID env var set to the shared `Registry` object created by
 *     attestation_registry's `init` (publish output prints it).
 *   - The sui CLI's keystore at `~/.sui/sui_config/sui.keystore`, with the
 *     active address funded on testnet.
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';

import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { fromBase64, normalizeSuiAddress, toHex } from '@mysten/sui/utils';
import type { SuiClientTypes } from '@mysten/sui/client';

import {
  makeClient,
  readPubfile,
  boxAddress,
  createBoxTx,
  attestAuditTx,
  auditAttestationType,
  revokeTx,
  listAttestations,
  type AttestationInfo,
  type PublishedPackages,
} from './lib/index.js';

const KEYSTORE_PATH = join(homedir(), '.sui', 'sui_config', 'sui.keystore');
const PUBFILE_PATH = join(import.meta.dirname, '..', 'Pub.testnet.toml');

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

function randomSubject(): string {
  return normalizeSuiAddress('0x' + toHex(randomBytes(32)));
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

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      rpc: { type: 'string' },
      subject: { type: 'string' },
    },
  });

  const client = makeClient(values.rpc);
  const signer = loadKeypair();
  const sender = signer.toSuiAddress();
  const pkgs: PublishedPackages = readPubfile(PUBFILE_PATH);
  const registryId = requireEnv('REGISTRY_ID');

  const subject = values.subject ? normalizeSuiAddress(values.subject) : randomSubject();
  const boxAddr = boxAddress(registryId, subject);
  const auditType = auditAttestationType({
    attestationRegistryPkg: pkgs.attestationRegistry,
    auditExamplePkg: pkgs.auditExample,
  });
  const auditCapType = `${pkgs.attestationRegistry}::attestation_registry::RevocationCap<${pkgs.auditExample}::audit::Audit>`;

  console.log(`sender:        ${sender}`);
  console.log(`registry:      ${registryId}`);
  console.log(`subject:       ${subject}`);
  console.log(`box address:   ${boxAddr}`);

  console.log('\n▶ TX 1 — create_box');
  {
    const tx = new Transaction();
    createBoxTx(tx, {
      attestationRegistryPkg: pkgs.attestationRegistry,
      registryId,
      subject,
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ TX 2 — attest_audit (will be revoked, score=60)');
  let revokeAttId: string;
  let revokeAttRef: { objectId: string; version: string; digest: string };
  let revokeCapId: string;
  {
    const tx = new Transaction();
    const cap = attestAuditTx(tx, {
      auditExamplePkg: pkgs.auditExample,
      registryId,
      subject,
      score: 60,
    });
    tx.transferObjects([cap], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    const attIds = ok.createdByType.get(auditType) ?? [];
    const capIds = ok.createdByType.get(auditCapType) ?? [];
    if (attIds.length !== 1 || capIds.length !== 1) {
      throw new Error(`expected 1 attestation + 1 cap in TX 2, got ${attIds.length} + ${capIds.length}`);
    }
    revokeAttId = attIds[0]!;
    revokeCapId = capIds[0]!;
    revokeAttRef = ok.createdRefs.get(revokeAttId)!;
  }

  console.log('\n▶ TX 3 — attest_audit (active, score=95)');
  {
    const tx = new Transaction();
    const cap = attestAuditTx(tx, {
      auditExamplePkg: pkgs.auditExample,
      registryId,
      subject,
      score: 95,
    });
    tx.transferObjects([cap], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ Read — all Audit attestations on subject');
  let attestations = await listAttestations(client, boxAddr, {
    typeFilter: auditType,
    includeDisplay: true,
  });
  for (const att of attestations) {
    console.log('');
    printAttestation(att);
  }

  console.log('\n▶ TX 4 — revoke score=60 attestation');
  {
    const tx = new Transaction();
    revokeTx(tx, {
      attestationRegistryPkg: pkgs.attestationRegistry,
      boxId: boxAddr,
      capId: revokeCapId,
      attestationRef: revokeAttRef,
      attestationType: `${pkgs.auditExample}::audit::Audit`,
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ Read — all Audit attestations after revoke');
  attestations = await listAttestations(client, boxAddr, {
    typeFilter: auditType,
    includeDisplay: true,
  });
  for (const att of attestations) {
    console.log('');
    printAttestation(att);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
