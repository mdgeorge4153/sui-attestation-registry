module audit_example::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{
    Self,
    Box,
    RevocationCap,
};

/// Schema for an audit attestation. Defined here so that this package is the
/// minting authority for `Permit<Audit>`, which gates `attest_as<Audit>`.
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
        internal::permit<Audit>(),
        display_registry,
        vector[name_field(), description_field()],
        vector[
            b"Audit attestation".to_string(),
            b"Score: {data.score}/10 by {attester}".to_string(),
        ],
        ctx,
    );
}

/// Issue an Audit attestation about the subject owned by `box`. Recorded
/// `attester` is `audit_example`'s own package address (via `attest_as`).
/// Returns the cap; the caller decides whether to retain it (to revoke later)
/// or transfer it (to delegate or commit).
public fun attest_audit(
    box: &mut Box,
    score: u8,
    ctx: &mut TxContext,
): RevocationCap<Audit> {
    attestation_registry::attest_as<Audit>(
        internal::permit<Audit>(),
        box,
        Audit { score },
        ctx,
    )
}

/// As `attest_audit`, but the attestation expires at `expires_at_ms` (Unix ms).
public fun attest_audit_with_expiry(
    box: &mut Box,
    score: u8,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): RevocationCap<Audit> {
    attestation_registry::attest_as_with_expiry<Audit>(
        internal::permit<Audit>(),
        box,
        Audit { score },
        expires_at_ms,
        ctx,
    )
}

fun name_field(): String { b"name".to_string() }
fun description_field(): String { b"description".to_string() }
