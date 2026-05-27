# Sui Attestation Registry PoC

A Move primitive for typed, on-chain attestations about arbitrary subjects
(packages, addresses, anything that has an `ID`), plus a TypeScript library
and CLI demo that exercises it.

The design is **off-chain-primary**: attestations are stored under a
deterministic, type-filterable on-chain layout that's cheap to enumerate from
indexers; cross-cutting behaviors like expiration and dependency tracking are
expressed as Display-field **conventions** rather than additional Move types.

## Repo layout

```
packages/
  attestation_registry/       — core Move package: Registry, Box, Attestation, RevocationCap
  audit_example/              — sample schema: Audit { score: u8 }
  vuln_example/               — sample "negative" schema: Vulnerability { severity, cve_id, description }
ts/
  lib/                        — TypeScript library: query helpers, PTB builders, conventions evaluator
  demo.ts                     — end-to-end CLI exercising the lifecycle
CONVENTIONS.md                — Display-field conventions (expires_at, requires, …)
FUTURE-EXTENSIONS.md          — design memos for surfaces deliberately deferred from v0
```

## Concepts in one paragraph

A `Registry` is a shared singleton, parent of one `Box` per attestation
subject. The Box's address is `derived_object::derive_address(registry, subject)`
— computable off-chain — so consumers can enumerate every attestation about
a subject via `getOwnedObjects(box_address, filter={StructType: …})`, with
server-side type filtering. Each `Attestation<T>` is owned by its Box via
transfer-to-object. Attestations are issued by `attestation_registry::attest`
gated by `Permit<T>` (only `T`'s defining package can call it), so the
recorded attester is `T`'s package — bound to the type at compile time, not
denormalized into a field. Revocation is bearer-token: `attest` returns a
`RevocationCap<T>` whose holder can flip the attestation's `active` flag via
`revoke`. Time-based effectiveness (expiration), dependency relationships
(`requires`), and other cross-cutting concerns sit in the Display layer per
the conventions in `CONVENTIONS.md` — the registry itself stays minimal.

## Building and testing

Each Move package builds and tests independently. Run from the package's
directory:

```bash
cd packages/attestation_registry && sui move test
cd packages/audit_example       && sui move test
cd packages/vuln_example        && sui move test
```

You'll need a `sui` CLI new enough to support the `#[error(code = …)]`
attribute and the `type_name::original_id` native helper — the testnet
release line at the time of writing (`v1.73.0`) is sufficient. Install or
update via `suiup install sui@testnet`.

## Running the TS demo

The demo creates a fresh Box, issues two `Attestation<Audit>` (score 60 and
score 95), lists them with their Display rendering, revokes the score-60 one,
and re-lists to show the `active=false` transition.

Prerequisites:

1. Test-publish all three packages to testnet, sharing one ephemeral
   pubfile across them so each resolves dependencies against the others'
   just-published addresses. `test-publish`'s default pubfile location is
   the package directory, so pass `--pubfile-path` explicitly to point at
   the same file at the repo root (where `ts/demo.ts` looks for it):
   ```bash
   PUBFILE="$PWD/Pub.testnet.toml"
   (cd packages/attestation_registry && sui client test-publish --pubfile-path "$PUBFILE")
   (cd packages/audit_example        && sui client test-publish --pubfile-path "$PUBFILE")
   (cd packages/vuln_example         && sui client test-publish --pubfile-path "$PUBFILE")
   ```
   `Pub.testnet.toml` is gitignored — it's ephemeral and per-user.
   (`sui client publish` would instead write `Published.toml` for a
   permanent, checked-in deployment; the PoC defaults to ephemeral.)
   Alternatively, `sui client test-publish --publish-unpublished-deps
   --pubfile-path "$PUBFILE"` on, say, `audit_example` deploys it and its
   unpublished dependencies in one shot.

2. Note the `Registry` object's ID from the first publish's output (a shared
   object of type `…::attestation_registry::Registry`). Export it:
   ```bash
   export REGISTRY_ID=0x…
   ```

3. The demo loads your keypair from `~/.sui/sui_config/sui.keystore` (the
   sui CLI's default location). Your active address needs testnet SUI for
   gas.

Then:

```bash
cd ts
pnpm install
pnpm demo
```

The demo prints transaction digests and the rendered Display for each
attestation before and after the revoke.

Options:

- `--rpc <url>` — override the default testnet gRPC endpoint (point at a
  fork, devnet, etc.).
- `--subject <hex-id>` — re-use a specific subject ID. Default: a fresh
  random ID per run, so `create_box` doesn't collide on re-runs.

## Conventions evaluator

`ts/lib/conventions.ts` implements `isEffective(attestation, ctx)`:
combines on-chain `active` with the `expires_at` and `requires` Display
conventions documented in `CONVENTIONS.md`. The evaluator walks the
`requires` graph; cycles are treated as ineffective.

## Branches

- `mdgeorge/draft` — TTO mainline (current).
- `mdgeorge/box-dof-reference` — DOF-storage snapshot from an earlier design
  iteration; preserved for comparison. See the commit log for the rationale
  for moving to TTO.

## Further reading

- `CONVENTIONS.md` — schema-level conventions for cross-cutting behaviors.
- `FUTURE-EXTENSIONS.md` — on-chain inspection APIs (borrow/put_back,
  data-by-copy) deferred from v0 with the design memos preserved.
