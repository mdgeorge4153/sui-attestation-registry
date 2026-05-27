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
    b"A Box already exists for this subject";

#[error(code = 1)]
const EBoxDoesNotExist: vector<u8> =
    b"No Box exists for this subject; call create_box first";

#[error(code = 2)]
const ERevokeMismatch: vector<u8> =
    b"RevocationCap doesn't match the attestation being revoked";

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Per-subject child of `Registry`. Owns every attestation about its subject
/// via transfer-to-object; the Attestation lives at the Box's address.
///
/// The Box's address is `derived_object::derive_address(registry, subject)`,
/// so off-chain consumers can compute it from `(registry_id, subject_id)` and
/// enumerate via `getOwnedObjects(box_addr, filter={StructType: ...})` —
/// native server-side type filtering, no client-side post-filter.
public struct Box has key {
    id: UID,
    subject: ID,
}

/// Typed attestation about `subject`. Stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`, no `drop`). External
/// callers have no way to obtain an `Attestation<T>` by value (no public
/// function returns one), and even if they did they couldn't transfer it
/// (`public_transfer` requires `store`), wrap it in another struct (Move
/// forbids storing `key` objects inside other objects), or drop it. The only
/// disposition of an `Attestation<T>` is through this module's `revoke`,
/// which receives it internally and re-transfers it to the owning Box.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
    active: bool,
}

/// Bearer-token authority to revoke a single `Attestation<T>`. Returned by
/// `attest` and consumed by `revoke`. Holding the cap *is* the authorization
/// — there is no separate sender check.
///
/// To commit irrevocably, transfer the cap to `@0x0` (or any other unspendable
/// address). To delegate, transfer to a multisig or another address.
public struct RevocationCap<phantom T> has key, store {
    id: UID,
    attestation_id: ID,
}

/// Emitted by every `attest` call. Indexers filter by the phantom `T`
/// (which becomes part of the event's fully-qualified Move type — RPC
/// supports filtering by struct-type) and key by `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted by every `revoke` call. Same shape as `Attested` for symmetry.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

// === Setup ===

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Create the per-subject `Box`. Aborts `EBoxAlreadyExists` if one already
/// exists for this `subject`.
public fun create_box(registry: &mut Registry, subject: ID) {
    assert!(!derived_object::exists(&registry.id, subject), EBoxAlreadyExists);
    let id = derived_object::claim(&mut registry.id, subject);
    transfer::share_object(Box { id, subject });
}

// === Accessors ===

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// `true` iff `self` has not been revoked. Time-based effectiveness (e.g.
/// expiration) is expressed via Display conventions, not via this field —
/// see CONVENTIONS.md.
public fun is_active<T: store>(self: &Attestation<T>): bool { self.active }

/// Original-publish address of `T`'s defining package. Useful for on-chain
/// trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address { type_name::original_id<T>() }

// === Attest / Revoke ===

/// Attest about `subject` (under `registry`) with `data`. Requires a
/// `Permit<T>` proving the call originated from `T`'s defining package.
/// Aborts `EBoxDoesNotExist` if no Box exists for this subject (call
/// `create_box` first). Returns a `RevocationCap<T>` that can later be used
/// to revoke this attestation.
public fun attest<T: store>(
    registry: &Registry,
    subject: ID,
    data: T,
    _: Permit<T>,
    ctx: &mut TxContext,
): RevocationCap<T> {
    assert!(derived_object::exists(&registry.id, subject), EBoxDoesNotExist);
    let box_addr = derived_object::derive_address(object::id(registry), subject);
    let attestation = Attestation<T> {
        id: object::new(ctx),
        subject,
        data,
        active: true,
    };
    let attestation_id = object::id(&attestation);
    event::emit(Attested<T> { subject });
    transfer::transfer(attestation, box_addr);
    RevocationCap<T> { id: object::new(ctx), attestation_id }
}

/// Revoke the attestation referenced by `rcv`. Aborts `ERevokeMismatch` if
/// the receiving ticket and the `RevocationCap` reference different
/// attestations.
public fun revoke<T: store>(
    box: &mut Box,
    cap: RevocationCap<T>,
    rcv: Receiving<Attestation<T>>,
    _ctx: &TxContext,
) {
    let RevocationCap { id: cap_uid, attestation_id: cap_id } = cap;
    object::delete(cap_uid);
    assert!(transfer::receiving_object_id(&rcv) == cap_id, ERevokeMismatch);
    let mut a = transfer::receive(&mut box.id, rcv);
    a.active = false;
    event::emit(Revoked<T> { subject: a.subject });
    transfer::transfer(a, box.id.to_address());
}

// === Display ===

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>` (only `T`'s defining module can mint
/// it); one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`, `{active}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// One field is appended automatically: `active` rendering `true`/`false`.
/// Schemas adopting cross-cutting conventions (`expires_at`, `requires`,
/// etc. — see CONVENTIONS.md) include those fields themselves.
public fun register_display<T: store>(
    display_registry: &mut DisplayRegistry,
    mut fields: vector<String>,
    mut values: vector<String>,
    _: Permit<T>,
    ctx: &mut TxContext,
) {
    fields.push_back(b"active".to_string());
    values.push_back(b"{active}".to_string());

    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        std::internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display_registry::share(display);

    // Burn the DisplayCap so the template is permanently immutable.
    transfer::public_transfer(cap, @0x0);
}

// === Test seam ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Test-only mirror of the `borrow`/`put_back` pattern documented in
/// docs/future-extensions.md. Production callers can't reach this, so the
/// hot-potato discipline isn't required here — tests just receive,
/// inspect, and put back manually.
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
