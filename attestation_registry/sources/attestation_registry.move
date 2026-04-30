module attestation_registry::attestation_registry;

use std::internal::Permit;
use std::string::String;
use sui::clock::Clock;
use sui::derived_object;
use sui::display;
use sui::dynamic_field as df;
use sui::package::{Self, Publisher};

/// Aborts when an attestation for `(registry, T, subject, sender)` already exists.
const EAttestationAlreadyExists: u64 = 0;

/// Aborts when a caller other than the original attester tries to revoke.
const ENotAttester: u64 = 1;

/// Aborts when revoking an already-revoked attestation.
const EAlreadyRevoked: u64 = 2;

/// Aborts when a `Display<Attestation<T>>` has already been registered for `T`.
const EDisplayAlreadyRegistered: u64 = 3;

/// One-time witness, consumed in `init` to mint a `Publisher`.
public struct ATTESTATION_REGISTRY has drop {}

/// Shared singleton. Parents all derived attestation objects and holds the
/// `Publisher` used to authorize `Display<Attestation<T>>` creation.
public struct Registry has key {
    id: UID,
    publisher: Publisher,
}

/// Derivation key for an attestation's address. Never stored — constructed at
/// attest-time, hashed by `derived_object::claim`, then dropped.
//
// TODO: The derived object should be a Box which owns the attestations, rather
// than each attestation being its own derived object
public struct AttestationKey<phantom T> has copy, drop, store {
    subject: ID,
    attester: address,
}

/// Current state of an `Attestation`. `ActiveUntil` carries its expiration; a
/// stored `Expired` variant is deliberately omitted because Move can't transition
/// state based on time — use `is_expired(&clock)` or `is_effective(&clock)` to
/// derive that from the clock.
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

/// Claim a `Publisher` from the OTW, wrap it in a `Registry`, and share it.
fun init(otw: ATTESTATION_REGISTRY, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    transfer::share_object(Registry {
        id: object::new(ctx),
        publisher,
    });
}

// NOTE: code quality checklist; test-only functions go at the end
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ATTESTATION_REGISTRY {}, ctx);
}

/// Create a shared `Attestation<T>` at the deterministic address derived from
/// `(registry, subject, sender, T)`. Aborts if one already exists for this triple.
public fun attest<T: store>(
    registry: &mut Registry,
    subject: ID,
    data: T,
    ctx: &mut TxContext,
): ID {
    // TODO: use receiver syntax
    attest_internal(registry, subject, data, option::none(), ctx)
}

/// As `attest`, but additionally sets `expires_at_ms` (Unix milliseconds).
public fun attest_with_expiry<T: store>(
    registry: &mut Registry,
    subject: ID,
    data: T,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): ID {
    attest_internal(registry, subject, data, option::some(expires_at_ms), ctx)
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

/// Dynamic-field marker recording that a `Display<Attestation<T>>` has been registered.
public struct DisplayRegistered<phantom T>() has copy, drop, store;

/// Publish an immutable `Display<Attestation<T>>`. Authorized by `Permit<T>`, so
/// only `T`'s defining module can call this, and only once per `T`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{attester}`, `{data}`, `{status}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// A `status` display field is appended automatically; the call aborts if
/// `fields` already contains that key.
public fun register_display<T: store>(
    _: Permit<T>,
    registry: &mut Registry,
    mut fields: vector<String>,
    mut values: vector<String>,
    ctx: &mut TxContext,
) {
    assert!(
        !df::exists_(&registry.id, DisplayRegistered<T>()),
        EDisplayAlreadyRegistered,
    );
    df::add(&mut registry.id, DisplayRegistered<T>(), true);
    fields.push_back(b"status".to_string());
    values.push_back(b"{status.expires_at_ms:ts | status}".to_string());
    // TODO: this uses display v1; in display v2 we need permit not publisher,
    // so we don't need to store it in the registry
    let mut display = display::new_with_fields<Attestation<T>>(
        &registry.publisher, fields, values, ctx,
    );
    display::update_version(&mut display);
    transfer::public_freeze_object(display);
}
