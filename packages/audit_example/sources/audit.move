module audit_example::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{Self, Box, RevocationCap};
use attestation_registry::with_expiry::{Self, WithExpiry};

/// Audit attestation payload. Defined here so audit_example is the
/// `Permit<Audit>` minting authority and the recorded attester for every
/// `Attestation<Audit>` is audit_example's published address.
public struct Audit has store, drop {
    score: u8,
}

/// One-shot setup: register the immutable `Display<Attestation<Audit>>`.
/// Should be called once shortly after publish; aborts on second call
/// (V2 enforcement via `display_registry`).
public fun register_audit_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Audit>(
        std::internal::permit<Audit>(),
        display_registry,
        vector[name_field(), description_field()],
        vector[
            b"Audit attestation".to_string(),
            b"Score: {data.score}/10".to_string(),
        ],
        ctx,
    );
}

/// Issue an Audit attestation about the subject owned by `box`. Returns the
/// revocation cap.
public fun attest_audit(
    box: &mut Box,
    score: u8,
    ctx: &mut TxContext,
): RevocationCap<Audit> {
    attestation_registry::attest<Audit>(
        std::internal::permit<Audit>(),
        box,
        Audit { score },
        ctx,
    )
}

/// Issue an Audit attestation that expires at `expires_at_ms` (Unix ms).
/// The resulting attestation type is `Attestation<WithExpiry<Audit>>`; the
/// recorded attester (per `attestation_registry`'s outer-type resolution
/// rule) is `with_expiry`'s package address rather than audit_example's.
public fun attest_audit_with_expiry(
    box: &mut Box,
    score: u8,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): RevocationCap<WithExpiry<Audit>> {
    with_expiry::attest_with_expiry<Audit>(
        std::internal::permit<Audit>(),
        box,
        Audit { score },
        expires_at_ms,
        ctx,
    )
}

/// The numeric audit score.
public fun score(self: &Audit): u8 { self.score }

fun name_field(): String { b"name".to_string() }
fun description_field(): String { b"description".to_string() }
