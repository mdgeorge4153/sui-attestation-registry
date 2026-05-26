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

/// Aborts when the `Receiving<Attestation<T>>` ticket passed to `revoke`
/// doesn't refer to the attestation the `RevocationCap` is keyed to.
const EWrongAttestationId: u64 = 1;

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

// TODO(mike): review macro-vs-invariant tradeoff
/// Typed attestation about `subject`. Stored as an object owned-by-Box via
/// transfer-to-object.
///
/// `store` is required because `with_attestation!` expands into caller
/// modules, which means the put-back-after-borrow must use
/// `transfer::public_transfer` (works across module boundaries) rather than
/// the package-private `transfer::transfer`.
///
/// **Security-critical invariant**: no public function in this module returns
/// `Attestation<T>` by value. Consumers borrow via the `with_attestation!`
/// macro; only `revoke` receives the value internally and immediately
/// re-transfers it to the owning Box. Adding any public function that returns
/// or wraps `Attestation<T>` by value would let callers transfer attestations
/// away from their owning Box, breaking the deterministic-address-per-subject
/// enumeration property and the cap-keyed revocation model.
public struct Attestation<T: store> has key, store {
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

// TODO(mike): revisit Receiving<T> ergonomics on review
/// Mark the attestation referenced by `rcv` as revoked. The cap and the
/// receiving ticket must agree on the attestation id; otherwise aborts
/// `EWrongAttestationId`.
public fun revoke<T: store>(
    box: &mut Box,
    cap: RevocationCap<T>,
    rcv: Receiving<Attestation<T>>,
    ctx: &TxContext,
) {
    let RevocationCap { id, attestation_id } = cap;
    object::delete(id);
    assert!(transfer::receiving_object_id(&rcv) == attestation_id, EWrongAttestationId);
    let mut a = transfer::receive(&mut box.id, rcv);
    a.status = Status::Revoked;
    event::emit(Revoked {
        attestation_id,
        subject: a.subject,
        type_name: type_name::with_original_ids<T>().into_string(),
        revoker: ctx.sender(),
    });
    transfer::transfer(a, box.id.to_address());
}

// TODO(mike): review — this leaks &mut UID, letting external callers bypass
// the with_attestation! discipline. Required because the macro expands in
// caller-module scope; restricting this to public(package) would block
// cross-package use of the macro (e.g. verifier packages downstream).
/// Exposes `&mut UID` of a `Box` so that `with_attestation!` (and any other
/// macro that needs to do `transfer::receive` against the Box) can expand at
/// the caller's site. External callers who call `transfer::public_receive`
/// directly with this UID can extract attestations by value and break the
/// owned-by-Box enumeration invariant — convention requires using
/// `with_attestation!` instead.
public fun box_uid_mut(self: &mut Box): &mut UID { &mut self.id }

/// Inlined receive-then-borrow-then-replace pattern. Expands at the call site
/// into a three-line `receive` / call closure / `public_transfer` sequence.
/// Pays the `&mut Box` cost (TTO requires it for the receive call) but lets
/// callers operate on `&Attestation<T>` without manually shuffling the value.
///
/// The closure may not return a value (Move 2024 doesn't have a nameable unit
/// type for macro return positions). Callers wanting to extract data should
/// capture into outer variables via `&mut` references in the closure.
public macro fun with_attestation<$T: store>(
    $box: &mut Box,
    $rcv: Receiving<Attestation<$T>>,
    $f: |&Attestation<$T>|,
) {
    let box = $box;
    let a = sui::transfer::public_receive(box.box_uid_mut(), $rcv);
    $f(&a);
    sui::transfer::public_transfer(a, sui::object::id_address(box));
}

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

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
