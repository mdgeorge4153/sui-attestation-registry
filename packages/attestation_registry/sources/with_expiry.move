/// Generic expiration wrapper for attestation payloads. Schemas that want
/// time-bounded effectiveness wrap their data type as `WithExpiry<T>` and
/// attest with `Attestation<WithExpiry<T>>` via `attest_with_expiry`.
///
/// Note on attester identity: because `Attestation<WithExpiry<T>>`'s
/// outermost type is rooted in this module, the recorded attester (in the
/// `Attested` event) is this module's package address — not `T`'s defining
/// package. Schemas that need their own package to be the recorded attester
/// should embed an `expires_at_ms` field in their own type instead of
/// wrapping with `WithExpiry`.
module attestation_registry::with_expiry;

use std::internal::Permit;
use sui::clock::Clock;
use attestation_registry::attestation_registry::{Self, Attestation, Box, RevocationCap};

/// Wraps a payload `T` with an explicit expiration time. Has `store` (so it
/// can be the `data` of an `Attestation<WithExpiry<T>>`) but intentionally
/// **not** `drop` — once constructed, the expiration commitment is permanent
/// unless the attestation is revoked.
public struct WithExpiry<T: store> has store {
    inner: T,
    expires_at_ms: u64,
}

/// Construct a new `WithExpiry<T>` wrapping `inner` with the given expiration
/// time (Unix milliseconds).
public fun new<T: store>(inner: T, expires_at_ms: u64): WithExpiry<T> {
    WithExpiry { inner, expires_at_ms }
}

/// Borrow the wrapped payload.
public fun inner<T: store>(self: &WithExpiry<T>): &T { &self.inner }

/// `true` iff `attestation` is both non-revoked and not yet past its
/// expiration. Combines `attestation_registry::is_effective` with the
/// expiration check.
public fun is_in_effect<T: store>(
    attestation: &Attestation<WithExpiry<T>>,
    clock: &Clock,
): bool {
    attestation.is_effective() &&
        clock.timestamp_ms() < attestation.data().expires_at_ms
}

/// Attest with an expiration-wrapped payload. The caller's `Permit<T>` is
/// proof that they're `T`'s defining package; this module mints the outer
/// `Permit<WithExpiry<T>>` (legitimate because it's `WithExpiry`'s defining
/// module) and forwards to `attestation_registry::attest`.
public fun attest_with_expiry<T: store>(
    _: Permit<T>,
    box: &mut Box,
    inner: T,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): RevocationCap<WithExpiry<T>> {
    attestation_registry::attest<WithExpiry<T>>(
        std::internal::permit<WithExpiry<T>>(),
        box,
        WithExpiry { inner, expires_at_ms },
        ctx,
    )
}
