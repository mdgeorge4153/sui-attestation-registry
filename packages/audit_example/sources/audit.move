module audit_example::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{Self, Registry, RevocationCap};

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
        display_registry,
        vector[name_field(), description_field()],
        vector[
            b"Audit attestation".to_string(),
            b"Score: {data.score}/10".to_string(),
        ],
        std::internal::permit<Audit>(),
        ctx,
    );
}

/// Issue an Audit attestation about `subject`. Returns the revocation cap.
public fun attest_audit(
    registry: &Registry,
    subject: ID,
    score: u8,
    ctx: &mut TxContext,
): RevocationCap<Audit> {
    attestation_registry::attest<Audit>(
        registry,
        subject,
        Audit { score },
        std::internal::permit<Audit>(),
        ctx,
    )
}

/// The numeric audit score.
public fun score(self: &Audit): u8 { self.score }

fun name_field(): String { b"name".to_string() }
fun description_field(): String { b"description".to_string() }
