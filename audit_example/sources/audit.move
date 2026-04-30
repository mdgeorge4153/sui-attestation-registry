module audit_example::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{Self, Registry};

public struct Audit has store, drop {
    score: u8,
}

/// One-shot setup: register the immutable `Display<Attestation<Audit>>`. Should
/// be called once shortly after publish. Aborts on second call (V2 enforcement).
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

/// Issue an Audit attestation about `subject` with `score`.
public fun attest_audit(
    registry: &mut Registry,
    subject: ID,
    score: u8,
    ctx: &mut TxContext,
): ID {
    attestation_registry::attest(registry, subject, Audit { score }, ctx)
}

/// Issue an Audit attestation that expires at `expires_at_ms` (Unix ms).
public fun attest_audit_with_expiry(
    registry: &mut Registry,
    subject: ID,
    score: u8,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): ID {
    attestation_registry::attest_with_expiry(
        registry,
        subject,
        Audit { score },
        expires_at_ms,
        ctx,
    )
}

fun name_field(): String { b"name".to_string() }
fun description_field(): String { b"description".to_string() }
