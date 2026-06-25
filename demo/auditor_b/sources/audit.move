module auditor_b::audit;

use std::internal;
use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Registry, Box, Attestation};

/// Audit attestation payload. Defined here so auditor is the
/// `Permit<Audit>` minting authority and the recorded attester for every
/// `Attestation<Audit>` is auditor's published address.
public struct Audit has store, drop {
    /// Human-readable summary of the audit, surfaced via the `description`
    /// presentation field.
    description: String,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
    /// Report publication date (ms since epoch), surfaced via the
    /// `publish_date` convention.
    publish_date_ms: u64,
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

/// One-shot setup: register the append-only `Display<Attestation<Audit>>` with
/// the full presentation set (name, description, link, image, publish date).
/// Should be called once shortly after publish; aborts on second call
/// (V2 enforcement via `display_registry`).
public fun register_audit_display(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    registry.register_display(
        display_registry,
        internal::permit<Audit>(),
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
            b"image_url".to_string(),
            b"publish_date".to_string(),
        ],
        vector[
            b"Audit attestation".to_string(),
            b"{data.description}".to_string(),
            b"{data.report_url}".to_string(),
            b"https://example.com/auditor-icon.svg".to_string(),
            b"{data.publish_date_ms:ts}".to_string(),
        ],
        ctx,
    );
}

/// Issue an `Attestation<Audit>` about `subject`. Gated by the `AuditAdminCap`,
/// the single authority over this auditor's attestations; mints the
/// `Permit<Audit>` the registry's `attest` requires (only this module can).
public fun attest_audit(
    _: &AuditAdminCap,
    registry: &Registry,
    subject: ID,
    description: String,
    report_url: String,
    publish_date_ms: u64,
    ctx: &mut TxContext,
) {
    registry.attest(
        internal::permit<Audit>(),
        subject,
        Audit { description, report_url, publish_date_ms },
        ctx,
    );
}

/// Revoke an `Attestation<Audit>`. Gated by the `AuditAdminCap`; mints the
/// `Permit<Audit>` the registry's `revoke` requires (only this module can).
public fun revoke_audit(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<Audit>>,
) {
    box.revoke(internal::permit<Audit>(), rcv);
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AuditAdminCap {
    AuditAdminCap { id: object::new(ctx) }
}
