module attestation_registry::attestation_registry;

use std::ascii;
use std::internal::Permit;
use std::string::String;
use std::type_name;
use sui::address;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};
use sui::event;
use sui::transfer::Receiving;

/// Aborts when `create_box` is called twice for the same subject.
const EBoxAlreadyExists: u64 = 0;

/// Aborts when an `AttestationBorrow` hot potato is discharged with the wrong
/// `Box` or the wrong `Attestation` value (i.e. the hot potato was opened
/// against a different box/attestation than the one being put back or revoked).
/// Implementation-oriented; should not occur in well-formed usage.
const EBorrowMismatch: u64 = 1;

/// Aborts when `revoke` is called with a `RevocationCap` whose
/// `attestation_id` doesn't match the attestation being revoked.
const ERevokeMismatch: u64 = 2;

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

/// State of an `Attestation`. Expiration is intentionally not represented here
/// — schemas that need expiry wrap their data in `with_expiry::WithExpiry<T>`.
public enum Status has copy, drop, store {
    Active,
    Revoked,
}

/// Typed attestation about `subject`. Stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`). External callers who
/// obtain an `Attestation<T>` by value (via `borrow`) cannot:
/// (1) transfer it elsewhere — `transfer::public_transfer` requires
///     `key + store`, and the private `transfer::transfer` is restricted to
///     this module;
/// (2) wrap it in another struct — struct fields can hold `key`-only types
///     only if the enclosing struct doesn't itself need `store`, and Move
///     forbids storing a `key` object inside another object;
/// (3) drop it — no `drop` ability.
/// The only ways to discharge an `Attestation<T>` by value are `put_back`
/// or `revoke`, both of which re-anchor it at its owning Box. The hot
/// potato `AttestationBorrow` reinforces this: it has no abilities, so it
/// must also be passed to one of those discharge functions. Bytecode-
/// enforced; no discipline note required.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
    status: Status,
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

/// Hot potato handed out alongside an `Attestation<T>` by `borrow`. Has no
/// abilities (no `drop`, `store`, `copy`, or `key`), so the borrow checker
/// forces the caller to discharge it via `put_back` or `revoke` before the
/// transaction ends. Carries the originating box's address and the
/// attestation's id, both verified by the discharge functions to prevent
/// the caller from swapping in a different value or a different box.
public struct AttestationBorrow {
    box_addr: address,
    attestation_id: ID,
}

/// Emitted by every `attest` call. `attester` is resolved at mint time from
/// the outermost type's original publish address; `type_name` lets indexers
/// filter or group without reparsing.
public struct Attested has copy, drop {
    attestation_id: ID,
    subject: ID,
    attester: address,
    type_name: ascii::String,
}

/// Emitted by every `revoke` call. `revoker` is `tx_context::sender()` at
/// revoke time, which may differ from the original attester if the cap was
/// transferred.
public struct Revoked has copy, drop {
    attestation_id: ID,
    subject: ID,
    type_name: ascii::String,
    revoker: address,
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

/// `true` iff `self` has not been revoked. Schemas that need expiration
/// chain this with their own time-based check (e.g.
/// `with_expiry::is_in_effect`).
public fun is_effective<T: store>(self: &Attestation<T>): bool {
    match (&self.status) {
        Status::Active => true,
        Status::Revoked => false,
    }
}

/// Original-publish address of `T`'s defining package — the same value
/// recorded as `attester` in `Attested` events for `Attestation<T>`. Useful
/// for on-chain trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address {
    let t = type_name::with_original_ids<T>();
    let s = t.address_string();
    address::from_ascii_bytes(s.as_bytes())
}

// === Attest / Revoke ===

/// Attest about `box.subject` with `data`. Returns a `RevocationCap<T>` that
/// can later be used to revoke this attestation. The `Permit<T>` proves the
/// call originated from `T`'s defining package; that package's original
/// publish address is recorded as the attester (in the emitted `Attested`
/// event — not in the struct).
public fun attest<T: store>(
    _: Permit<T>,
    box: &mut Box,
    data: T,
    ctx: &mut TxContext,
): RevocationCap<T> {
    let attestation = Attestation<T> {
        id: object::new(ctx),
        subject: box.subject,
        data,
        status: Status::Active,
    };
    let attestation_id = object::id(&attestation);
    event::emit(Attested {
        attestation_id,
        subject: box.subject,
        attester: attester_of<T>(),
        type_name: type_name::with_original_ids<T>().into_string(),
    });
    transfer::transfer(attestation, box.id.to_address());
    RevocationCap<T> { id: object::new(ctx), attestation_id }
}

/// Discharge an `AttestationBorrow` by revoking the attestation. Consumes
/// the matching `RevocationCap<T>`. Aborts `EBorrowMismatch` if the box or
/// attestation doesn't match the hot potato; aborts `ERevokeMismatch` if
/// the cap's recorded `attestation_id` doesn't match the attestation being
/// revoked.
public fun revoke<T: store>(
    box: &mut Box,
    attestation: Attestation<T>,
    cap: RevocationCap<T>,
    borrow: AttestationBorrow,
    ctx: &TxContext,
) {
    let AttestationBorrow { box_addr, attestation_id } = borrow;
    let RevocationCap { id: cap_uid, attestation_id: cap_id } = cap;
    object::delete(cap_uid);
    assert!(box.id.to_address() == box_addr, EBorrowMismatch);
    assert!(object::id(&attestation) == attestation_id, EBorrowMismatch);
    assert!(cap_id == attestation_id, ERevokeMismatch);
    let mut a = attestation;
    a.status = Status::Revoked;
    event::emit(Revoked {
        attestation_id,
        subject: a.subject,
        type_name: type_name::with_original_ids<T>().into_string(),
        revoker: ctx.sender(),
    });
    transfer::transfer(a, box_addr);
}

// === Read-borrow lifecycle ===

/// Receive an attestation out of its `Box` for on-chain inspection. Returns
/// the `Attestation<T>` value along with a non-droppable `AttestationBorrow`
/// hot potato that *must* be discharged before the transaction ends —
/// either by `put_back` (leaving the attestation unchanged) or `revoke`
/// (transitioning it to `Revoked`). Bytecode-enforced; the type system
/// forbids any other disposition.
public fun borrow<T: store>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): (Attestation<T>, AttestationBorrow) {
    let a = transfer::receive(&mut box.id, rcv);
    let attestation_id = object::id(&a);
    let borrow = AttestationBorrow {
        box_addr: box.id.to_address(),
        attestation_id,
    };
    (a, borrow)
}

/// Discharge an `AttestationBorrow` without changes: re-anchor the
/// attestation at its originating Box. Aborts `EBorrowMismatch` if the
/// caller supplies a different box or a different attestation than the one
/// recorded in the hot potato.
public fun put_back<T: store>(
    box: &mut Box,
    attestation: Attestation<T>,
    borrow: AttestationBorrow,
) {
    let AttestationBorrow { box_addr, attestation_id } = borrow;
    assert!(box.id.to_address() == box_addr, EBorrowMismatch);
    assert!(object::id(&attestation) == attestation_id, EBorrowMismatch);
    transfer::transfer(attestation, box_addr);
}

// === Display ===

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>` (only `T`'s defining module can mint
/// it); one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`, `{status}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// One field is appended automatically: `status` rendering the variant.
/// Schemas that wrap with `WithExpiry<T>` and want an `expires_at` row
/// include it themselves in `fields` / `values`.
public fun register_display<T: store>(
    _: Permit<T>,
    display_registry: &mut DisplayRegistry,
    mut fields: vector<String>,
    mut values: vector<String>,
    ctx: &mut TxContext,
) {
    fields.push_back(b"status".to_string());
    values.push_back(b"{status}".to_string());

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
