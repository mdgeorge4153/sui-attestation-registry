# Design and Rationale

This document records *why* the on-chain design is shaped the way it is. For
*how to use it* see `README.md`; for deferred ideas `FUTURE-EXTENSIONS.md`; for
the SIP-56 comparison `SIP-56-COMPARISON.md`; for schema-level Display
conventions `CONVENTIONS.md`.

## Core model

The whole design follows from four choices:

- **Off-chain primary.** The dominant access pattern is off-chain consumers
  (wallets, explorers, the TS library) reading attestations about a subject.
  Every on-chain choice was weighed against "does this make the off-chain read
  better, the same, or worse?"
- **Attester = `T`'s defining package.** The attester recorded for an
  `Attestation<T>` is `type_name::original_id<T>()` — the original publish
  address of `T`'s defining package, not the signer. This is
  bytecode-verifiable: an `Attestation<T>` can only exist because `T`'s package
  minted it, since Move restricts constructing a `T` value to that package.
- **Permanent, `key`-only attestations.** `Attestation<T>` has `key` only, and
  no public function returns one by value, so external callers can't transfer,
  wrap, or drop it. Once created it cannot be destroyed; its only dispositions
  are `attest` and `revoke` (see "Lifecycle invariant").
- **Status is which box owns it.** Each subject has two claimed boxes — *active*
  and *revoked*. An attestation carries no status field; it is revoked iff it
  lives in the revoked box, so enumerating the active box yields exactly the
  un-revoked set.

Everything cross-cutting — revocation *policy*, expiration, dependency
relationships — is pushed out of the core: revocation authority to the schema
(via `Permit<T>`), the rest to Display-field conventions evaluated off-chain.

## Storage: per-subject `Box`, transfer-to-object

```
Registry (shared singleton)
  ├── BoxKey{subject, revoked:false} → active Box  → owns un-revoked Attestation<T> (TTO)
  └── BoxKey{subject, revoked:true}  → revoked Box → owns revoked Attestation<T> (TTO)
```

- **`Registry`** is a `key`-only shared singleton, created in `init`; its UID is
  the parent for all per-subject boxes.
- **`Box`** is `key`-only and per-subject. `create_box` claims *both* boxes for
  a subject at once (aborting `EBoxAlreadyExists` on a repeat). Each box address
  is `derived_object::derive_address(registry, BoxKey { subject, revoked })` —
  *computable off-chain* from `(registry_id, subject_id)`. Consumers read a
  subject's un-revoked attestations from the active box via
  `getOwnedObjects(box_addr, filter={StructType: ...})`, with native
  server-side type filtering.
- **`Attestation<T: store>`** is owned by the active Box via
  `transfer::transfer(attestation, box.id.to_address())`; `revoke` moves it to
  the revoked box.

The Box is a real object (not just a derived address) because it stores its
`BoxKey` — so a viewer knows the subject and which box, the address is
recomputable, and an attestation's status is readable on-chain as
`box_revoked(owner)` — and its parent `registry: ID`, so `revoke` can derive the
sibling box without `&Registry`. It also gives `transfer::receive` a `&mut UID`
to borrow at the address; without an object there, nothing could receive an
attestation back. Earlier iterations encoded status as an on-chain `enum Status`
and then an `active: bool` flag; both made every off-chain read pay a per-object
status filter, which box membership avoids.

### Why TTO, not DOF

DOF was built and rejected (reference snapshot: `mdgeorge/box-dof-reference`).
Listing "all `Attestation<Audit>` on subject S" under DOF needs a client-side
filter over all of S's dynamic fields, because DOF queries have no server-side
type filter; TTO's `getOwnedObjects` does. The cost is that TTO reads need
`&mut Box` (`transfer::receive` needs `&mut UID`) rather than DOF's `&Box`; we
accept it because the read story dominates. On-chain inspection patterns we
deferred are in `FUTURE-EXTENSIONS.md`.

## Attestation lifecycle invariant

```move
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
}
```

`key`-only (no `store`, `drop`, or `copy`), and no public function returns one by
value — so external callers can't obtain one, and even with one in hand
`public_transfer` needs `store`, Move forbids wrapping a `key` object, and no
`drop` means it can't be discarded. The only legal disposition is `revoke`
(active box → revoked box). Bytecode-enforced; no discipline note required.

## Attester identity: trust and gating

Because the attester is `T`'s defining package rather than the signer:

- Trust lists are keyed by package address — "I trust this auditor" means "I
  trust attestations from this package."
- New attestation types added in package upgrades inherit the same attester
  identity. Upgrade authority is attestation-dynamics authority anyway, so this
  composes.
- Permissionless attestation is a schema-level opt-in: the schema exposes a
  public constructor and (typically) puts `sender: address` in its data. The
  type-level attester is still the schema package; the per-attestation signer
  lives in the data.

`attest` is *not* gated by `Permit<T>` — Move's construction rule does that job.
`register_display` and `revoke` *are*, because authority over an attestation's
presentation and lifecycle is distinct from the authority to construct its data
(without the permit, anyone holding a `T` could race to register
`Display<Attestation<T>>` for that type).

## Revocation: `Permit<T>`-gated, policy in the schema

```move
public fun attest<T: store>(box: &Box, data, ctx): ID
public fun revoke<T: store>(box: &mut Box, _: Permit<T>, rcv: Receiving<Attestation<T>>)
```

`attest` takes the subject's active `Box` (aborts if handed the revoked one) and
returns the new attestation's `ID` — the one piece a schema can't otherwise
recover, since the object goes straight to the Box — so a schema can bind a
bearer cap to it, log it, or ignore it. `revoke` receives the attestation and
moves it to the revoked box (address derived from the Box's stored `registry`),
emitting `Revoked<T>`.

The move and event stay uniform here; the *authority* does not. `revoke` is
gated by `Permit<T>`, which only `T`'s defining module can mint, so the base
prescribes no revocation policy — each schema gates its own `revoke_*` wrapper
(bearer cap, admin cap, multisig, …) and then mints the permit. This costs the
base nothing in expressiveness; every policy, including a per-attestation bearer
cap, is reconstructable schema-side (see "Schema-level patterns").

Revocation is **terminal in the current bytecode** — no function un-revokes —
but not cryptographically permanent: the revoked box is a real shared object, so
a future upgrade could add a receive-back path. The property given up is
bytecode-provable irrevocability; a schema is permanent only by exposing no
revoke path. That's weaker than burning a cap, but upgrade authority is already
attestation-dynamics authority.

## Display registration: park the DisplayCap on the Registry

`register_display<T>(...)` creates `Display<Attestation<T>>`, applies the
schema's fields, shares it, and transfers the `DisplayCap` to the Registry's
address (TTO). The cap authorizes `set`/`unset`/`clear`, so the template is
meant to be immutable — but the framework exposes no way to destroy a
DisplayCap. Parking it on the Registry keeps it out of circulation without
minting an extra immovable wrapper, and a future upgrade could destroy it if a
`DisplayCap::destroy` ever lands. (An earlier iteration froze a wrapper struct
around the cap; owning it on the Registry is simpler.)

## Events: phantom T, minimal payload

```move
public struct Attested<phantom T> has copy, drop { subject: ID }
public struct Revoked<phantom T> has copy, drop { subject: ID }
```

- `phantom T` makes the event's fully-qualified Move type the filterable
  surface: subscribers filter by
  `eventType: "0xPKG::attestation_registry::Attested<0xAUD::audit::Audit>"`
  directly, with no string parsing.
- `subject` is the only field; everything else is recoverable from `tx.effects`
  or the attestation object. Denormalizing (attester, id, revoker) onto events
  creates two-sources-of-truth hazards without saving indexers any query work.

## Display-mixin conventions

Cross-cutting behaviors like expiration (`expires_at`) are Display field
conventions, evaluated off-chain by `ts/src/conventions.ts` and any consumer
that adopts them (see `CONVENTIONS.md`). They don't need on-chain enforcement
(off-chain primary), and modeling them as Move wrappers created composability
problems — `WithExpiry<Audit<OtterSec>>` is awkward to nest, and wrappers
confused the attester-resolution rule. Display fields stack naturally: a schema
just includes the relevant fields in its `register_display` call.

## Schema-level patterns

The base is minimal; schemas express their semantics in their own package, not
via registry flags:

- **Revocation policy**: a schema gates its `revoke_*` wrapper before minting
  `Permit<T>`. `audit_example` uses one `AuditAdminCap` (one authority over both
  `Audit` and `AuditV2`); the other extreme — a per-attestation bearer cap
  (`VulnRevokeCap` with a `receiving_object_id` guard) — is the planned
  `vuln_example` fast-follow. No `revoke_*` wrapper = permanent.
- **Permissioned vs permissionless**: a private data constructor is
  permissioned (only the schema package attests); a public constructor plus a
  `sender: address` field is permissionless with the signer captured in the
  data.
- **Expiration**: opt into the `expires_at` Display convention by including its
  template entry in `register_display`; consumers apply the semantics.

## What this design deliberately doesn't have

- **On-chain type registry** (SIP-56's `register_type`). Type discoverability is
  off-chain — enumerate events, filter by struct-type via RPC.
- **Pinning by package publisher.** Curation of trust signals is a consumer
  concern; package authors are the wrong principal. See `SIP-56-COMPARISON.md`.
- **On-chain inspection of attestation data** as a public API. The
  `borrow`/`put_back` hot-potato pattern is deferred to `FUTURE-EXTENSIONS.md`
  until a concrete consumer appears.
- **A built-in revocation policy.** The base gates `revoke` on `Permit<T>` and
  leaves the authority model to the schema; in particular, no sender-keyed
  authorization in the base.
- **`store` on `Attestation<T>`.** It's `key`-only; external callers can't wrap,
  transfer, or drop it.

## Related documents

- `README.md` — quickstart, repo layout, running the demo.
- `CONVENTIONS.md` — schema-level Display conventions and their semantics.
- `FUTURE-EXTENSIONS.md` — design memos for deferred surfaces (on-chain
  inspection).
- `SIP-56-COMPARISON.md` — point-by-point comparison with SIP-56.
