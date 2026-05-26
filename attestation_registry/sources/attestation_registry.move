module attestation_registry::attestation_registry;

use std::ascii;
use std::internal::Permit;
use std::string::String;
use std::type_name;
use sui::address;
use sui::clock::Clock;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};
use sui::dynamic_object_field as dof;
use sui::event;

// NOTES
// TODO: versioning? only necessary as a way to stop operations, probably not necessary here (not a lot at stake)

// Question about TTO: if we want to use it on-chain, we'd need to do Receiving<T>, this would cause the version
// number of the Attestation to change, which would harm parallelism, but in a low-throughput system it's possible

// an interesting question: why can't we have both good on-chain access (like
// DOF) and also good off-chain access (like TTO, which we can filter)? Ideally
// we could borrow DOF immutably with good concurrency, or query DOF off-chain
// with filtering by type

// next steps: build off-chain queries to get a feel for the tradeoffs



/// Aborts when `create_box` is called twice for the same subject.
const EBoxAlreadyExists: u64 = 0;

/// Aborts when `revoke` is called with a `RevocationCap` that doesn't match
/// the supplied `attestation_id`.
const EWrongAttestationId: u64 = 1;

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Per-subject child of `Registry`. Owns every attestation about its subject as
/// a dynamic-object-field child, keyed by the attestation's own `ID`.
///
/// The Box's address is `derived_object::derive_address(registry, subject)`, so
/// off-chain consumers can compute it from `(registry_id, subject_id)` and
/// enumerate via `getDynamicFields` to find every attestation about a subject —
/// regardless of attestation type or attester.
public struct Box has key {
    id: UID,
    subject: ID,
}

/// State of an `Attestation`. `ActiveUntil` carries its expiration. A stored
/// `Expired` variant is deliberately omitted because Move can't transition state
/// based on time alone — `is_effective(&clock)` derives that from a `Clock`.
public enum Status has copy, drop, store {
    Active,
    ActiveUntil { expires_at_ms: u64 },
    Revoked,
}

/// Typed attestation about `subject` made by `attester`. Stored as a
/// dynamic-object-field child of its `Box`.
///
/// `store` is required by `dynamic_object_field` storage. **Security-critical
/// invariant**: no public function in this module returns `Attestation<T>` by
/// value. Consumers borrow it via `attestation` / `has_attestation` accessors
/// that go through `&Box`; the registry retains exclusive structural ownership.
/// Adding any public function that returns or wraps `Attestation<T>` by value
/// would let callers transfer attestations out of their owning `Box`, breaking
/// the deterministic-address-per-subject enumeration property and the
/// cap-keyed revocation model.
public struct Attestation<T: store> has key, store {
    id: UID,
    subject: ID,
    attester: address,
    data: T,
    status: Status,
}

/// Bearer-token authority to revoke a single `Attestation<T>`. Returned by
/// each `attest*` and consumed by `revoke`. Holding the cap *is* the
/// authorization — there is no separate sender check.
///
/// To commit irrevocably, transfer the cap to `@0x0` (or any other unspendable
/// address). To delegate, transfer the cap to a multisig or another address.
public struct RevocationCap<phantom T> has key, store {
    id: UID,
    attestation_id: ID,
}

// TODO: why? not necessary
/// Emitted by `create_box`.
public struct BoxCreated has copy, drop {
    registry_id: ID,
    box_id: ID,
    subject: ID,
}

/// Emitted by every `attest*` flow. `type_name` uses original publish IDs so
/// upgrades to `T`'s defining package don't change the recorded type identity.
public struct Attested has copy, drop {
    box_id: ID,
    attestation_id: ID,
    subject: ID,
    attester: address,
    type_name: ascii::String,
    expires_at_ms: Option<u64>,
}

/// Emitted by `revoke`. `attester` is the original attester recorded at
/// attest time; `revoker` is `tx_context::sender()` at revoke time (which may
/// differ if the cap was transferred).
public struct Revoked has copy, drop {
    box_id: ID,
    attestation_id: ID,
    type_name: ascii::String,
    attester: address,
    revoker: address,
}

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Create the per-subject `Box`. Aborts `EBoxAlreadyExists` if one already
/// exists for this `subject`.
// TODO: idiomatic way is to return the Box and have a share function
// this allows creating then attesting in the same PTB
public fun create_box(
    registry: &mut Registry,
    subject: ID,
) {
    assert!(!derived_object::exists(&registry.id, subject), EBoxAlreadyExists);
    let id = derived_object::claim(&mut registry.id, subject);
    let box_id = id.to_inner();
    event::emit(BoxCreated {
        registry_id: registry.id.to_inner(),
        box_id,
        subject,
    });
    transfer::share_object(Box { id, subject });
}

/// Attest about `box.subject` as the transaction sender. Returns a
/// `RevocationCap<T>` that can later be used to revoke this attestation.
public fun attest<T: store>(
    box: &mut Box,
    data: T,
    ctx: &mut TxContext,
): RevocationCap<T> {
    box.attest_internal(ctx.sender(), data, option::none(), ctx)
}

/// As `attest`, but the attestation expires at `expires_at_ms` (Unix ms).
public fun attest_with_expiry<T: store>(
    box: &mut Box,
    data: T,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): RevocationCap<T> {
    box.attest_internal(ctx.sender(), data, option::some(expires_at_ms), ctx)
}

// question: do we even need expiration? it only helps on-chain, but even
// that's not useful; it can be folded into the <T> of Attestation<T> if it's
// necessary for a particular thing; could also publish with templates

/// Attest as `T`'s defining package. The `Permit<T>` proves the call originated
/// from that package's code; the recorded `attester` is the package's *original*
/// publish address (so upgrades don't re-attribute past attestations).
public fun attest_as<T: store>(
    _: Permit<T>,
    box: &mut Box,
    data: T,
    ctx: &mut TxContext,
): RevocationCap<T> {
    box.attest_internal(package_address<T>(), data, option::none(), ctx)
}

/// As `attest_as`, but the attestation expires at `expires_at_ms` (Unix ms).
public fun attest_as_with_expiry<T: store>(
    _: Permit<T>,
    box: &mut Box,
    data: T,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): RevocationCap<T> {
    box.attest_internal(package_address<T>(), data, option::some(expires_at_ms), ctx)
}

/// Build an `Attestation<T>`, store it as a DOF child of `box`, mint the
/// matching cap, and emit `Attested`. Internal entry point shared by all four
/// public attest variants.
fun attest_internal<T: store>(
    box: &mut Box,
    attester: address,
    data: T,
    expires_at_ms: Option<u64>,
    ctx: &mut TxContext,
): RevocationCap<T> {
    let status = if (expires_at_ms.is_none()) {
        Status::Active
    } else {
        Status::ActiveUntil { expires_at_ms: *expires_at_ms.borrow() }
    };
    let attestation = Attestation<T> {
        id: object::new(ctx),
        subject: box.subject,
        attester,
        data,
        status,
    };
    let attestation_id = object::id(&attestation);
    event::emit(Attested {
        box_id: box.id.to_inner(),
        attestation_id,
        subject: box.subject,
        attester,
        type_name: type_name::with_original_ids<T>().into_string(),
        expires_at_ms,
    });
    // TODO: need TTO here
    //  - TTO: objects are owned by other objects
    //     - advantage: you get offchain access
    //       give me all owned objects of this type
    //     - can filter on types but not values
    //     - use typescript SDK to create attestations and fetch them
    //     - TTO is cheaper gas-wise than DF because the DF and DOF have a key object
    //  - DOF, DF
    //     - can't do give me all attestations from ottersec
    //     -
    dof::add(&mut box.id, attestation_id, attestation);
    RevocationCap<T> { id: object::new(ctx), attestation_id }
}

/// Mark the attestation identified by `attestation_id` as revoked. Consumes
/// `cap`. Aborts `EWrongAttestationId` if `cap` doesn't match `attestation_id`.
///
/// The explicit `attestation_id` argument is redundant with `cap.attestation_id`
/// — the assertion guarantees they match — but it makes revoke transactions
/// self-describing in explorers and audit trails: the target attestation is
/// visible directly in the call without dereferencing the cap.
public fun revoke<T: store>(
    box: &mut Box,
    cap: RevocationCap<T>,
    attestation_id: ID,
    ctx: &TxContext,
) {
    let RevocationCap { id, attestation_id: cap_id } = cap;
    assert!(cap_id == attestation_id, EWrongAttestationId);
    object::delete(id);
    let box_id = box.id.to_inner();
    let attester = {
        let a: &mut Attestation<T> = dof::borrow_mut(&mut box.id, attestation_id);
        a.status = Status::Revoked;
        a.attester
    };
    event::emit(Revoked {
        box_id,
        attestation_id,
        type_name: type_name::with_original_ids<T>().into_string(),
        attester,
        revoker: ctx.sender(),
    });
}

/// Borrow the attestation identified by `id` from `box`. Aborts if no DOF entry
/// exists at this id, or if the entry's value type doesn't match `T`.
public fun attestation<T: store>(box: &Box, id: ID): &Attestation<T> {
    dof::borrow(&box.id, id)
}

/// Whether `box` holds an `Attestation<T>` with this `id`.
public fun has_attestation<T: store>(box: &Box, id: ID): bool {
    dof::exists_with_type<ID, Attestation<T>>(&box.id, id)
}

/// The attestation-id this cap can revoke. Useful for off-chain tooling that
/// wants to know which attestation a held cap targets, without consuming it.
public fun cap_attestation_id<T>(self: &RevocationCap<T>): ID {
    self.attestation_id
}

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// Who issued this attestation. Either `tx_context::sender()` (for `attest`) or
/// the original publish address of `T`'s defining package (for `attest_as`).
public fun attester<T: store>(self: &Attestation<T>): address { self.attester }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// `true` iff `self` is active (not revoked, and if an expiration is set, `clock` is before it).
public fun is_effective<T: store>(self: &Attestation<T>, clock: &Clock): bool {
    match (&self.status) {
        Status::Active => true,
        Status::ActiveUntil { expires_at_ms } => clock.timestamp_ms() < *expires_at_ms,
        Status::Revoked => false,
    }
}

/// Original-publish address of `T`'s defining package, parsed from the runtime
/// `TypeName`. Uses `get_with_original_ids` so that upgrades to `T`'s package
/// don't re-attribute existing or future attestations.
fun package_address<T>(): address {
    let t = type_name::with_original_ids<T>();
    let s = t.address_string();
    address::from_ascii_bytes(s.as_bytes())
}

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>`, so only `T`'s defining module can call
/// this; one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{attester}`, `{data}`, `{status}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// Two display fields are appended automatically: `status` (renders the variant
/// name for every attestation) and `expires_at` (renders an ISO 8601 timestamp
/// for the `ActiveUntil` variant; absent for `Active`/`Revoked`). The call
/// aborts if `fields` already contains either of those keys.
public fun register_display<T: store>(
    _: Permit<T>,
    display_registry: &mut DisplayRegistry,
    mut fields: vector<String>,
    mut values: vector<String>,
    ctx: &mut TxContext,
) {
    fields.push_back(b"status".to_string());
    values.push_back(b"{status}".to_string());
    fields.push_back(b"expires_at".to_string());
    values.push_back(b"{status.expires_at_ms:ts}".to_string());

    // Caller's `Permit<T>` proves they own `T`'s defining module.
    // We mint `Permit<Attestation<T>>` ourselves (only this module can,
    // since `Attestation` is defined here) to satisfy V2's API.
    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        std::internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display_registry::share(display);

    // Burn the `DisplayCap` so the templates are permanently immutable. There's
    // no public destructor on `DisplayCap`, so transfer-to-`@0x0` is the
    // closest we can get to making it unreachable.
    transfer::public_transfer(cap, @0x0);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
