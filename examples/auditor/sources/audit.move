module auditor::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};

/// Audit attestation payload. Defined here so auditor is the
/// `Permit<Audit>` minting authority and the recorded attester for every
/// `Attestation<Audit>` is auditor's published address.
public struct Audit has store, drop {
    score: u8,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
}

/// Single-party authority to *control* this auditor's attestations: whoever
/// holds this cap can both issue and revoke any `Attestation<Audit>`. Created
/// once at publish and transferred to the publisher. This is one
/// authority-policy choice among many — the base registry prescribes none;
/// each schema picks its own and supplies the `Permit` `revoke` requires.
public struct AuditAdminCap has key, store {
    id: UID,
}

/// Mint the auditor's `AuditAdminCap` at publish and hand it to the publisher.
fun init(ctx: &mut TxContext) {
    transfer::transfer(AuditAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// One-shot setup: register the immutable `Display<Attestation<Audit>>`.
/// Should be called once shortly after publish; aborts on second call
/// (V2 enforcement via `display_registry`).
public fun register_audit_display(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Audit>(
        registry,
        display_registry,
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
        ],
        vector[
            b"Audit attestation".to_string(),
            b"Score: {data.score}/100".to_string(),
            b"{data.report_url}".to_string(),
        ],
        std::internal::permit<Audit>(),
        ctx,
    );
}

/// Issue an Audit attestation into `box` (the subject's active box). Gated by
/// the `AuditAdminCap`, the single authority over this auditor's attestations.
public fun attest_audit(
    _: &AuditAdminCap,
    box: &Box,
    score: u8,
    report_url: String,
    ctx: &mut TxContext,
) {
    attestation_registry::attest<Audit>(box, Audit { score, report_url }, ctx);
}

/// Revoke an `Attestation<Audit>`. Gated by the `AuditAdminCap`; mints the
/// `Permit<Audit>` the registry's `revoke` requires (only this module can).
public fun revoke_audit(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<Audit>>,
) {
    attestation_registry::revoke<Audit>(box, std::internal::permit<Audit>(), rcv);
}

/// The numeric audit score.
public fun score(self: &Audit): u8 { self.score }

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AuditAdminCap {
    AuditAdminCap { id: object::new(ctx) }
}
