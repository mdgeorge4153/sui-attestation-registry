module attestation_registry::attestation_registry;

use std::internal::Permit;
use std::string::String;
use sui::clock::Clock;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};

/// Aborts when an attestation for `(registry, T, subject, sender)` already exists.
const EAttestationAlreadyExists: u64 = 0;

/// Aborts when a caller other than the original attester tries to revoke.
const ENotAttester: u64 = 1;

/// Aborts when revoking an already-revoked attestation.
const EAlreadyRevoked: u64 = 2;

/// Shared singleton. Parent UID for all derived attestation objects.
public struct Registry has key {
    id: UID,
}

// TODO: The derived object should be a Box which owns the attestations, rather
// than each attestation being its own derived object.
/// Derivation key for an attestation's address. Never stored — constructed at
/// attest-time, hashed by `derived_object::claim`, then dropped.
public struct AttestationKey<phantom T> has copy, drop, store {
    subject: ID,
    attester: address,
}

/// Current state of an `Attestation`. `ActiveUntil` carries its expiration; a
/// stored `Expired` variant is deliberately omitted because Move can't transition
/// state based on time — use `is_effective(&clock)` to derive that from the clock.
public enum Status has copy, drop, store {
    Active,
    ActiveUntil { expires_at_ms: u64 },
    Revoked,
}

/// Typed attestation about `subject` made by `attester`. Shared at a
/// deterministic address derived from `(Registry, AttestationKey<T>)`.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    attester: address,
    data: T,
    status: Status,
}

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
    });
}

/// Create a shared `Attestation<T>` at the deterministic address derived from
/// `(registry, subject, sender, T)`. Aborts if one already exists for this triple.
public fun attest<T: store>(
    registry: &mut Registry,
    subject: ID,
    data: T,
    ctx: &mut TxContext,
): ID {
    registry.attest_internal(subject, data, option::none(), ctx)
}

/// As `attest`, but additionally sets `expires_at_ms` (Unix milliseconds).
public fun attest_with_expiry<T: store>(
    registry: &mut Registry,
    subject: ID,
    data: T,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): ID {
    registry.attest_internal(subject, data, option::some(expires_at_ms), ctx)
}

fun attest_internal<T: store>(
    registry: &mut Registry,
    subject: ID,
    data: T,
    expires_at_ms: Option<u64>,
    ctx: &TxContext,
): ID {
    let attester = ctx.sender();
    let key = AttestationKey<T> { subject, attester };
    assert!(!derived_object::exists(&registry.id, key), EAttestationAlreadyExists);
    let uid = derived_object::claim(&mut registry.id, key);
    let status = if (expires_at_ms.is_none()) {
        Status::Active
    } else {
        Status::ActiveUntil { expires_at_ms: *expires_at_ms.borrow() }
    };
    let attestation = Attestation<T> {
        id: uid,
        subject,
        attester,
        data,
        status,
    };
    let id = object::id(&attestation);
    transfer::share_object(attestation);
    id
}

/// Mark `attestation` as revoked. Callable only by the original attester;
/// aborts if already revoked.
public fun revoke<T: store>(
    attestation: &mut Attestation<T>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == attestation.attester, ENotAttester);
    match (&attestation.status) {
        Status::Revoked => abort EAlreadyRevoked,
        _ => (),
    };
    attestation.status = Status::Revoked;
}

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// Who issued this attestation.
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

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>`, so only `T`'s defining module can call
/// this; one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{attester}`, `{data}`, `{status}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// A `status` display field is appended automatically; the call aborts if
/// `fields` already contains that key.
public fun register_display<T: store>(
    _: Permit<T>,
    display_registry: &mut DisplayRegistry,
    mut fields: vector<String>,
    mut values: vector<String>,
    ctx: &mut TxContext,
) {
    fields.push_back(b"status".to_string());
    values.push_back(b"{status.expires_at_ms:ts | status}".to_string());

    // Caller's `Permit<T>` proves they own `T`'s defining module.
    // We mint `Permit<Attestation<T>>` ourselves (only this module can,
    // since `Attestation` is defined here) to satisfy V2's API.
    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        internal::permit<Attestation<T>>(),
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
