module attestation_registry::attestation_registry;

use std::internal::Permit;
use std::string::String;
use std::type_name;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};
use sui::event;
use sui::transfer::Receiving;

#[error(code = 0)]
const EBoxAlreadyExists: vector<u8> =
    b"Boxes already exist for this subject";

#[error(code = 1)]
const EBoxRevoked: vector<u8> =
    b"Pass the subject's active Box, not its revoked one";

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Derived-address key for one of a subject's two boxes. `revoked: false` keys
/// the active box, `revoked: true` the revoked box; both are claimed, shared
/// `Box` objects (siblings under the same `Registry`), so off-chain consumers
/// compute either address from `(registry_id, subject_id)`.
public struct BoxKey has copy, drop, store {
    subject: ID,
    revoked: bool,
}

/// Per-subject child of `Registry`. Each subject has two, both created by
/// `create_box`: the *active* box (`key.revoked == false`) and the *revoked*
/// box (`key.revoked == true`). An attestation lives in one of them via
/// transfer-to-object, and its status *is* which box owns it — an attestation
/// is revoked iff its owner box's `key.revoked` is true.
///
/// The Box stores its own `key` (so its address is recomputable, and an
/// attestation's status is readable from its owner) and its parent `registry`
/// id (so `revoke` can derive the sibling box's address).
public struct Box has key {
    id: UID,
    key: BoxKey,
    registry: ID,
}

/// Typed attestation about `subject`, stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`, no `drop`). No public
/// function returns one by value, so external callers can't transfer, wrap, or
/// drop it. Its only dispositions are `attest` (into the active box) and
/// `revoke` (from the active box to the revoked box); its status is which box
/// owns it, not a field here.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
}

/// Emitted when an `Attestation<T>` is added for `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted when an `Attestation<T>` is revoked for `subject`.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

// === Setup ===

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Create and share a subject's two `Box`es (active + revoked). Aborts
/// `EBoxAlreadyExists` if they already exist.
public fun create_box(registry: &mut Registry, subject: ID) {
    let registry_id = object::id(registry);
    claim_box(registry, registry_id, BoxKey { subject, revoked: false });
    claim_box(registry, registry_id, BoxKey { subject, revoked: true });
}

/// Claim and share one box for `key`.
fun claim_box(registry: &mut Registry, registry_id: ID, key: BoxKey) {
    assert!(!derived_object::exists(&registry.id, key), EBoxAlreadyExists);
    let id = derived_object::claim(&mut registry.id, key);
    transfer::share_object(Box { id, key, registry: registry_id });
}

// === Accessors ===

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// The subject a `Box` holds attestations about.
public fun box_subject(box: &Box): ID { box.key.subject }

/// Whether `box` is the subject's revoked box. An attestation's status is
/// `is_revoked` of the box that owns it.
public fun is_revoked(box: &Box): bool { box.key.revoked }

/// Test-only: address of a subject's active (`revoked == false`) or revoked
/// (`revoked == true`) box. Tests use it to locate the two boxes; production
/// callers don't need it (off-chain consumers derive box addresses themselves,
/// and `BoxKey` is module-private so there's nothing to expose on-chain).
#[test_only]
public fun box_address(registry: &Registry, subject: ID, revoked: bool): address {
    derived_object::derive_address(object::id(registry), BoxKey { subject, revoked })
}

/// Original-publish address of `T`'s defining package. Useful for on-chain
/// trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address { type_name::original_id<T>() }

// === Attest / Revoke ===

/// Attest about `box`'s subject with `data`. Pass the subject's *active* `Box`
/// (aborts `EBoxRevoked` otherwise). Returns the new attestation's `ID` — the
/// one piece a schema can't otherwise recover (the object goes straight to the
/// box), so it can build whatever revocation authority it wants.
public fun attest<T: store>(box: &Box, data: T, ctx: &mut TxContext): ID {
    assert!(!box.key.revoked, EBoxRevoked);
    let subject = box.key.subject;
    let attestation = Attestation<T> { id: object::new(ctx), subject, data };
    let attestation_id = object::id(&attestation);
    event::emit(Attested<T> { subject });
    transfer::transfer(attestation, box.id.to_address());
    attestation_id
}

/// Revoke the attestation referenced by `rcv`: receive it from the active
/// `box` and move it to the subject's revoked box. Terminal — there is no
/// un-revoke. `rcv` alone identifies which attestation.
///
/// Gated by `Permit<T>`: only `T`'s defining module can mint one, so the
/// *policy* for who may revoke (a bearer cap, an admin cap, a multisig, …)
/// lives in that module, while the move and `Revoked<T>` event stay uniform
/// here — the same split as `register_display`.
public fun revoke<T: store>(
    box: &mut Box,
    _: Permit<T>,
    rcv: Receiving<Attestation<T>>,
) {
    assert!(!box.key.revoked, EBoxRevoked);
    let a = transfer::receive(&mut box.id, rcv);
    let subject = a.subject;
    let revoked_box = derived_object::derive_address(
        box.registry,
        BoxKey { subject, revoked: true },
    );
    event::emit(Revoked<T> { subject });
    transfer::transfer(a, revoked_box);
}

// === Display ===

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>` (only `T`'s defining module can mint
/// it); one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// Revocation is not a Display field — it's which box owns the attestation.
/// Schemas adopting cross-cutting conventions (`expires_at`, etc. — see
/// CONVENTIONS.md) include those fields themselves.
public fun register_display<T: store>(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    fields: vector<String>,
    values: vector<String>,
    _: Permit<T>,
    ctx: &mut TxContext,
) {
    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        std::internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display_registry::share(display);

    // The Display is meant to be immutable, but `DisplayCap` has no destroy.
    // Park it on the Registry: it can't be used to mutate the Display from
    // there, it's one fewer floating object than a frozen wrapper, and a
    // future upgrade could destroy it.
    // TODO: revisit if `DisplayCap::destroy` (or similar) lands.
    transfer::public_transfer(cap, object::id(registry).to_address());
}

// === Test seam ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun borrow_for_testing<T: store>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): Attestation<T> {
    transfer::receive(&mut box.id, rcv)
}

#[test_only]
public fun put_back_for_testing<T: store>(box: &mut Box, a: Attestation<T>) {
    transfer::transfer(a, box.id.to_address());
}
