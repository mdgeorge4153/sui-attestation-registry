# Design and Rationale

This document records *why* the on-chain design is shaped the way it is.
For *how to use it*, see `README.md`. For ideas we considered and deferred,
see `FUTURE-EXTENSIONS.md`. For the comparison with SIP-56, see
`SIP-56-COMPARISON.md`. For schema-level Display conventions, see
`CONVENTIONS.md`.

## Design pillars

- **Off-chain primary.** The dominant access pattern is off-chain
  consumers (wallets, indexers, the TS library) reading attestations
  about a subject. Every on-chain choice was evaluated against "does
  this make the off-chain read story better, the same, or worse?"
- **Minimal core, conventions for the rest.** The registry's Move
  surface is small: a Registry, per-subject Boxes, and typed
  Attestations whose only mutation is a `Permit<T>`-gated `revoke`.
  Anything cross-cutting — revocation *policy*, expiration, dependency
  relationships — is pushed out of the core: revocation authority to the
  schema, the rest to Display-field conventions evaluated off-chain.
- **Bytecode-verifiable identity.** The recorded attester for an
  `Attestation<T>` resolves to `T`'s defining package's *original*
  publish address. Trust signals are anchored to the package that
  defined the type, not to the keypair that signed the transaction.

## Storage: per-subject `Box`, transfer-to-object

```
Registry (shared singleton)
  ├── BoxKey{subject, revoked:false} → active Box  → owns un-revoked Attestation<T> (TTO)
  └── BoxKey{subject, revoked:true}  → revoked Box → owns revoked Attestation<T> (TTO)
```

- **`Registry`** is a `key`-only shared singleton, created in `init`.
  Its UID is the parent for all per-subject boxes.
- **`Box`** is `key`-only and per-subject. Each subject has two, claimed
  together by `create_box`: the *active* box (`key.revoked == false`) and
  the *revoked* box (`key.revoked == true`). The active box's address is
  `derived_object::derive_address(registry, BoxKey { subject, revoked:
  false })` — *computable off-chain* from `(registry_id, subject_id)`.
  Off-chain consumers fetch every un-revoked attestation about a subject
  from that address via `getOwnedObjects(box_addr, filter={StructType:
  ...})`, with native server-side type filtering.
- **Revoked box.** The sibling box (`revoked: true`) is where `revoke`
  moves attestations (see "Revocation"). Enumerating the active box yields
  exactly the un-revoked set, with no per-object status flag to read; the
  revoked box is read separately to list revoked attestations, and an
  attestation's status is the `revoked` of whichever box owns it.
- **`Attestation<T: store>`** is `key`-only, owned by the active Box via
  `transfer::transfer(attestation, box.id.to_address())`.

### Why TTO, not DOF

The DOF-keyed-by-attestation-id design was considered (and built — see
`mdgeorge/box-dof-reference` branch for a reference snapshot). The
deciding factor: with DOF, listing "all `Attestation<Audit>` on subject
S" requires a client-side filter pass over all of S's dynamic fields
because DOF queries don't support server-side type filtering. TTO does:
`getOwnedObjects(box_addr, filter={StructType: ...})` is a native RPC.

DOF gives slightly better on-chain ergonomics (immutable borrow needs
only `&Box`, parallelizable reads). TTO requires `&mut Box` for every
read because `transfer::receive` needs `&mut UID`. We accept the on-chain
cost because the read story is the dominant use case and TTO is materially
better there. See `FUTURE-EXTENSIONS.md` for the on-chain inspection
patterns we deferred.

### Why a Box at all (not transferring directly to the derived address)

The Box object exists for two reasons:

- It carries its `BoxKey` (`subject` + `revoked`), so a viewer who
  inspects the Box knows what it's about and whether it's the active or
  revoked box, and the address it should live at is recomputable.
- It carries the parent `registry: ID`, so `revoke` can derive the
  sibling (revoked) box's address from the Box alone — no `&Registry`.
- `transfer::receive` requires a `&mut UID` for the parent. Without an
  actual object at the derived address, there's no UID to borrow; you
  couldn't revoke (or do anything else that needs to take an attestation
  back).

`create_box(registry, subject)` is an explicit per-subject setup step.
Aborts `EBoxAlreadyExists` on second call for the same subject.

## `Attestation<T>` lifecycle invariant

```move
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
}
```

`Attestation<T>` is **`key`-only**: no `store`, no `drop`, no `copy`. External
callers have no way to obtain one by value (no public function returns one),
and even if they did:

- `transfer::public_transfer` requires `key + store`. Without `store`, no
  way to move it.
- Move forbids wrapping a `key` object inside another struct.
- No `drop` means they can't discard it.

The only legal disposition of an `Attestation<T>` is through this module's
`revoke`, which receives it from the active Box and transfers it to the
subject's revoked Box. Bytecode-enforced; no discipline note required.

## Revocation status by box membership, not a field

The attestation carries no status field at all. Revocation is encoded by
*which* box owns it: live attestations sit in the subject's active box, and
`revoke` moves an attestation to the revoked box (see "Revocation"). Since
each Box stores its own `BoxKey`, an attestation's status is also readable
on-chain from its owner — `box_revoked(owner)`. We tried an on-chain `enum
Status` and then an `active: bool` flag during earlier iterations; both made
every off-chain read pay a per-object status filter. Encoding status as box
membership removes that: enumerating the active box returns exactly the
un-revoked set, the revoked box the revoked set, and the struct stays `{ id,
subject, data }`.

## Attester identity: from `T`'s package, not the signer

The attester recorded on `Attested<T>` events is resolved at mint time via
`type_name::original_id<T>()` — the original publish address of `T`'s
defining package.

This is bytecode-verifiable: the existence of an `Attestation<T>` on-chain
proves that `T`'s defining package's code path was taken to mint it,
because constructing a `T` value is restricted to that package by Move's
struct construction rules. No separate `Permit<T>` is needed: producing a
`T` *is* the proof.

Consequences:

- Trust lists are keyed by package address. "I trust this auditor" is
  expressed at the granularity of "I trust attestations from this
  package."
- New attestation types added in package upgrades automatically inherit
  the same attester identity. Upgrade authority is attestation-dynamics
  authority anyway, so this composes correctly at the security level.
- Permissionless attestation is an opt-in schema-level choice: a schema
  exposes a public constructor and (typically) includes
  `sender: address` in its data. The recorded attester (at the type
  level) is still the schema package; the per-attestation signer lives
  in the data.

`attest` is *not* gated by `Permit<T>` — Move's construction rule does
the same job. `register_display` and `revoke` *are* gated by `Permit<T>`,
because authority over an attestation's presentation and lifecycle is not
the same as the authority to construct its data, and shouldn't fall to
whoever happens to hold a `T` value (without the permit, anyone could
race to register `Display<Attestation<T>>` for any T).

## Revocation: `Permit<T>`-gated, policy in the schema

```move
public fun attest<T: store>(box: &Box, data, ctx): ID
public fun revoke<T: store>(box: &mut Box, _: Permit<T>, rcv: Receiving<Attestation<T>>)
```

`attest` takes the subject's active `Box` (and aborts if handed the revoked
one). `revoke` receives the attestation from the active `Box` and transfers
it to the subject's revoked `Box`, whose address it derives from the Box's
stored `registry` id. The move and the `Revoked<T>` event live here, uniform
across every
attestation type — but the *authority* to call it does not. `revoke` is
gated by `Permit<T>`, which only `T`'s defining module can mint, so the
registry prescribes no revocation policy. Each schema decides who may
revoke and expresses it in its own `revoke_*` wrapper, which performs
whatever check it wants and then mints the permit.

`attest` returns the new attestation's `ID` — the one piece a schema
can't otherwise recover, since the object goes straight to the Box — so a
schema can bind a bearer cap to it, log it, or ignore it.

This splits the two things a built-in bearer cap used to bundle: the
*move + event* (kept uniform in the base) from the *authority model*
(delegated to the schema). It costs the base nothing in expressiveness —
every policy, including the exact per-attestation bearer cap, is
reconstructable schema-side (see "Schema-level patterns").

Revocation is **terminal in the current bytecode** — no function un-revokes —
but it is not cryptographically permanent: the revoked box is a real shared
object, so a future upgrade could add a function that receives an attestation
back out of it. The one
property the design gives up is bytecode-provable *irrevocability*: a
schema is permanent only by exposing no revoke path, which a later upgrade
could add. That's weaker than burning a cap, but upgrade authority is
already attestation-dynamics authority, so it composes.

## Display registration: park the DisplayCap on the Registry

`register_display<T>(...)` creates the `Display<Attestation<T>>`, applies the
fields the schema passed in, shares the Display, then transfers the
`DisplayCap` to the `Registry`'s address (TTO).

The DisplayCap authorizes `set`/`unset`/`clear` on the Display, so the
template is meant to be immutable — but the framework exposes no way to
destroy a DisplayCap. Parking it on the Registry keeps it out of circulation
(it can't be used to mutate the Display from there) without minting an extra
immovable wrapper object, and a future upgrade could destroy it if a
`DisplayCap::destroy` ever lands. (An earlier iteration froze a wrapper struct
around the cap instead; owning it on the Registry is simpler.)

## Events: phantom T, minimal payload

```move
public struct Attested<phantom T> has copy, drop { subject: ID }
public struct Revoked<phantom T> has copy, drop { subject: ID }
```

- `phantom T` makes the event's fully-qualified Move type the
  filterable surface. RPC subscribers filter by
  `eventType: "0xPKG::attestation_registry::Attested<0xAUD::audit::Audit>"`
  directly; no string parsing.
- `subject` is the only field, because nothing else is information that
  isn't already recoverable from `tx.effects` or from the attestation
  object itself. Denormalizing (attester, attestation_id, revoker, etc.)
  on events creates two-sources-of-truth hazards without saving any
  query work for indexers that ingest events.

## Display-mixin conventions

Cross-cutting behaviors like expiration (`expires_at`) are expressed as
Display field conventions, evaluated off-chain by `ts/src/conventions.ts`
and any consumer that adopts them. See `CONVENTIONS.md`.

Rationale: these behaviors don't need on-chain enforcement for trust
signals (the registry is off-chain primary), and putting them on-chain
as Move types created composability problems (`WithExpiry<Audit<OtterSec>>`
is awkward to nest; the attester resolution rule got confused by
wrappers). Display fields stack naturally — a schema adopting several
conventions just includes the corresponding fields in its
`register_display` call.

## Schema-level patterns

The registry is intentionally minimal; schemas express choices about
their attestation semantics in the schema package, not via registry
flags:

- **Revocation policy**: a schema gates its `revoke_*` wrapper however it
  likes before minting `Permit<T>`. `audit_example` uses a single
  `AuditAdminCap` (one authority revokes any audit, across both `Audit`
  and `AuditV2`). The other end of the range — a per-attestation bearer
  cap (`VulnRevokeCap` bound to the attestation id, with a
  `transfer::receiving_object_id` guard) — is the planned `vuln_example`
  schema, a fast-follow not in the positive MVP. A schema that exposes no
  `revoke_*` wrapper is permanent.
- **Permissioned vs. permissionless**: schemas decide whether to expose
  a public constructor for their data type. Private constructor =
  permissioned (only the schema package can attest). Public constructor
  + `sender: address` field on the data = permissionless with per-
  attestation signer captured in the data.
- **Expiration**: opt into the `expires_at` Display convention by
  including the corresponding template entry in `register_display`.
  Off-chain consumers apply the semantics; the registry doesn't know or
  care.

## What this design deliberately doesn't have

- **On-chain type registry** (analogue of SIP-56's `register_type`).
  Type discoverability is an off-chain concern (enumerate events,
  filter by struct-type via RPC).
- **Pinning by package publisher**. Curation of trust signals is a
  consumer concern; package authors are the wrong principal to control
  what trust signals get surfaced. See `SIP-56-COMPARISON.md` for the
  longer argument.
- **On-chain inspection of attestation data** as a public API. The
  `borrow`/`put_back` hot-potato pattern and the `T: copy` read-by-copy
  pattern were both worked through and deliberately deferred to
  `FUTURE-EXTENSIONS.md` until a concrete consumer materializes.
- **A built-in revocation policy**. The base gates `revoke` on
  `Permit<T>` and leaves the authority model (bearer cap, admin cap,
  multisig, …) to the schema — see "Revocation". In particular there is
  no sender-keyed authorization in the base.
- **Attestation `store` ability**. `Attestation<T>` is `key`-only;
  external callers can't wrap, transfer, or drop it.

## Related documents

- `README.md` — quickstart, repo layout, how to run the demo.
- `CONVENTIONS.md` — schema-level Display conventions (`expires_at`, …)
  and their semantics.
- `FUTURE-EXTENSIONS.md` — design memos for surfaces deferred from v0
  (on-chain inspection patterns).
- `SIP-56-COMPARISON.md` — point-by-point comparison with SIP-56 and
  why each remaining divergence is an improvement.
