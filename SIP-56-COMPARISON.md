# Comparison with SIP-56

[SIP-56 ("Attestation registry")](https://github.com/sui-foundation/sips/pull/56)
is an in-progress Informational SIP authored by Sidestream Labs that proposes
an "open standard for attesters to share signals about packages." Its
[reference implementation](https://github.com/sidestream-tech/sui-attestation-registry)
shaped a lot of the design conversation that led to this PoC.

This document records where the two designs diverge and why. The high-level
goal is the same; the disagreements are about which abstractions earn their
weight on-chain versus belong off-chain.

## Summary

| Dimension | SIP-56 | This PoC |
|---|---|---|
| Subject scope | Packages only (`receiver` is a package address) | Any `ID` |
| Attestation type registration | Explicit `register_type` step requiring `Publisher` | Implicit — any Move type `T` works; `register_display<T>` is the analog |
| Attest authorization | Permissionless `attest` + custom logic in schema package | `Permit<T>`-gated — only `T`'s defining package can mint the permit |
| Storage layout | Single central `Registry` holds all attestations | Per-subject `Box` (derived from `Registry`) owns its attestations via TTO |
| Off-chain enumeration | Iterate `Registry`'s dynamic fields | `getOwnedObjects(box_addr, filter={StructType: …})` — native server-side type filter |
| Highlighting | On-chain `pin`/`unpin` by package publisher | Off-chain (Display conventions; future possibility) |
| `attester` identity | `created_by` field = `tx.sender()` | Resolved at mint time from `T`'s package; recorded in `Attested` event |
| Revocation | `RevokeCap` returned at attest; schema may freeze it | `RevocationCap<T>` returned at attest; transfer to `@0x0` for irrevocable |
| Status model | `revoked_by: Option<address>` field | `active: bool` field (`Status` enum considered, dropped after expiration moved out) |
| Cross-cutting behaviors (expiry, requires) | Each schema bakes in its own | Display-field conventions evaluated off-chain (CONVENTIONS.md) |
| Display lifecycle | Frozen with `Publisher` at `register_type` | Frozen by burning `DisplayCap` to `@0x0` |

## Where the designs diverge — and why

### Subject scope: packages vs. any `ID`

SIP-56's `receiver: address` field specifically targets *packages*. The
implementation note that pin/unpin requires the receiver's `Publisher` only
makes sense if the receiver is a package.

This PoC's `subject: ID` field is type-erased and works for any object:
packages, addresses, NFTs, transactions, whatever. The Move primitive
doesn't know or care.

**Tradeoff**: SIP-56's narrower scope buys you the publisher-anchored pin
mechanism. The PoC's broader scope makes the primitive useful for trust
signals about non-package targets (e.g., reputation about user addresses,
attestations against transaction digests, etc.) at the cost of pin not
being expressible at the registry level.

We picked the more general primitive because we couldn't articulate a clear
reason "subject is always a package" should be a Move-level invariant.

### Type registration: explicit `register_type` vs. just-define-a-type

SIP-56 has a permissionless `register_type<T>` call that takes the schema
package's `Publisher` and registers `T` as an "attestation type." It then
freezes the `Publisher` and creates a frozen `Display<Attestation<T>>`.

This PoC has no equivalent step. Any Move type `T` is automatically usable
as `Attestation<T>` data; calling `attest<T>` is the only ceremony required.
Display registration (`register_display<T>`) is a separate, optional step
gated by the same `Permit<T>`.

**Tradeoff**: SIP-56's explicit registration gives a single observable
moment to enforce invariants ("Publisher is frozen, Display is set, etc."),
and gives the broader Sui ecosystem a registry of "known attestation types."
This PoC's just-use-a-type approach is lighter — fewer concepts to learn —
but lacks a single canonical "type X is an attestation type" event for
ecosystem-level enumeration.

For a Move primitive, we preferred minimalism. For an ecosystem standard,
SIP-56's explicit registration is probably the more honest framing.

### Attest authorization: permissionless vs. `Permit<T>`-gated

SIP-56's `attestation::attest` is permissionless — anyone can call it for
any registered type. Schemas wanting to restrict who can attest layer their
own check on top (typically by exposing only a wrapper that does the gating
before forwarding to `attest`).

This PoC's `attest<T>` requires `Permit<T>` from `std::internal`, which is
bytecode-restricted to `T`'s defining module. So only `T`'s defining package
can attest with `T`. Schemas wanting third-party attesters expose their own
gated wrappers.

**Tradeoff**: SIP-56's permissionless default is more flexible — anyone can
attest, and schemas opt into gating. The PoC's gated-by-default is more
opinionated — schemas opt into permissiveness by exposing public attest
helpers.

The PoC's choice was driven by wanting the `attester` field to mean "this
attestation was produced by *this* package's code path." That guarantee is
load-bearing for the trust model (a third party calling `attest_audit_with`
shouldn't be able to claim it was issued by the Audit protocol). SIP-56's
permissionless approach pushes that guarantee one layer up.

### Storage: central Registry vs. per-subject Box

SIP-56 stores all attestations under one central `Registry` (presumably via
dynamic fields keyed by subject + type). Enumerating attestations about a
specific package requires reading the Registry's children matching that key.

This PoC creates a `Box` per subject as a derived child of `Registry`.
Attestations are owned by the Box via transfer-to-object. The Box's address
is computable off-chain from `(registry_id, subject_id)`, and querying its
attestations is a single `getOwnedObjects(box_address, filter={StructType: …})`
call — native server-side type-filter, paginated, type-safe.

**Tradeoff**: SIP-56's central storage means one well-known location for
"all attestations ever." The PoC's per-subject Box means one well-known
location per subject — better-aligned with how readers usually slice the
data ("show me all attestations about *this* thing") and benefits from
native RPC filtering, but worse if you want to enumerate everything
globally.

For a trust-signals primitive, the per-subject access pattern is the
dominant query and the one we optimized for. The PoC's
`FUTURE-EXTENSIONS.md` covers cases where on-chain inspection matters.

### Highlighting: on-chain pin vs. off-chain convention

SIP-56's pin/unpin is a permissioned operation by the receiver's
`Publisher`. The intent: package owners highlight attestations they want
explorers to surface, reducing noise from low-quality attestations.

This PoC has no equivalent on-chain. Highlighting (or any reputational
weight on top of raw attestations) is left to off-chain consumers and could
be expressed as a future Display convention (e.g., the receiver issues their
own attestation that *requires* the third-party attestation, surfacing it
via the `requires` convention).

**Tradeoff**: SIP-56's pin keeps the relationship on-chain and indexer-
visible without bespoke consumer logic. The PoC's omission leaves
highlighting to convention but avoids putting "what the package owner
considers reputable" on-chain when this is fundamentally a UI/curation
concern.

We left pin out because we couldn't see how a generic Move primitive should
decide which attestations a subject owner wants highlighted — that judgment
varies by use case and platform. If the SIP gets to pin via convention,
that'd resolve the gap; alternatively, an explicit `pin_cap` model could be
added later without changing the rest of the design.

### `attester` identity: sender vs. type-package

SIP-56 records `created_by: address` = `tx.sender()` — whoever signed the
transaction that called `attest`.

This PoC resolves the attester at mint time from `T`'s defining package via
`type_name::original_id<T>()`. The struct itself doesn't carry an attester
field; the `Attested` event does (`attester: address`).

**Tradeoff**: SIP-56's sender-as-attester is simpler and matches the "user
signs a tx" mental model. The PoC's type-package-as-attester ties identity
to the schema rather than the keypair — i.e., "this attestation came from
the Audit protocol," not "Alice signed this." For schemas where the protocol
is the trust signal (third-party audit firms, dependency tracking, etc.),
this is the more useful identity.

A consequence: under SIP-56, multiple users can attest the same type with
different `created_by` values. Under the PoC, all attestations of type T
have the same `attester`. Mixing both models would be a layer-up concern.

### Status: `revoked_by: Option<address>` vs. `active: bool`

SIP-56 stores `revoked_by` as an optional address — `None` means active,
`Some(addr)` means revoked by that address.

This PoC has a plain `active: bool`, with revoker info captured in the
`Revoked` event instead of the struct.

**Tradeoff**: SIP-56's field carries more information per attestation
(who revoked it). The PoC's field is cheaper and avoids denormalizing
information that's already in the revocation event.

We went minimal here because the same reasoning that drops the `attester`
field from the struct (info available via tx context) applies to `revoked_by`.

## What we gained

- **Type-filtered enumeration via native RPC** — the core off-chain query
  story.
- **Schema-rooted attester identity** — "this attestation came from this
  protocol" is bytecode-verifiable.
- **Smaller core surface** — no `register_type`, no `pin`, no `created_by`/
  `revoked_by` denormalization on the struct.
- **General `subject: ID`** — works for trust signals about any object, not
  just packages.

## What we gave up

- **On-chain "official" type registry** — the explicit `register_type`
  observable moment.
- **Publisher-anchored pinning** — the package owner's curation surface.
- **Permissionless attest** — third parties have to go through a
  schema-exposed wrapper.
- **Global enumeration anchor** — to find all attestations ever you'd union
  results across all known schemas and subjects, not query a single
  Registry.

## Open questions if this were to converge with SIP-56

- Would `register_type` add enough ecosystem value to justify the
  on-chain step, even with most behaviors covered by Move types and
  Display conventions? If yes, could it be a thin convention (an
  `AttestationType<T>` marker registered in a separate package) rather
  than baking it into the core?
- Is pin/unpin essential, or can it move to a Display convention
  (`recommended_by`/`endorsed_by` fields keyed by package address) that
  off-chain consumers interpret?
- Does the schema-rooted attester model lose enough fidelity for
  user-attestation use cases that we'd want both? See the
  `UserAttestation<T>` sketch in `FUTURE-EXTENSIONS.md` for the wrapper
  approach.

## What this isn't

This isn't a recommendation that one design is correct and the other wrong.
SIP-56 is targeting an ecosystem standard with explorer/wallet integration
in mind; this PoC is targeting a minimal Move primitive that's easy to
reason about and extend at the schema layer. The two could plausibly
coexist — a SIP-56-style standard could be implemented *on top of* this
PoC's primitives by a schema package that mints attestations with a
`pinned_by` Display convention and registers itself via a sibling
`AttestationType` marker.
