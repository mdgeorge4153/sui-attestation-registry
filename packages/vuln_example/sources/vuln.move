/// Example of a "negative" attestation schema: each `Attestation<Vulnerability>`
/// asserts that the subject has a known vulnerability. Pairs naturally with
/// the `requires` display convention — a higher-level trust signal would
/// remain effective only if no unrevoked Vulnerability attestation exists
/// against the same subject.
module vuln_example::vuln;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{Self, Registry, RevocationCap};

/// Vulnerability attestation payload. Defined here so vuln_example is the
/// `Permit<Vulnerability>` minting authority — the recorded attester for
/// every `Attestation<Vulnerability>` is vuln_example's published address.
public struct Vulnerability has store, drop {
    /// Severity score 0–10 (CVSS-style).
    severity: u8,
    /// CVE identifier (e.g. "CVE-2026-1234").
    cve_id: String,
    /// Short human-readable description.
    description: String,
}

/// One-shot setup: register the immutable `Display<Attestation<Vulnerability>>`.
public fun register_vuln_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Vulnerability>(
        display_registry,
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"severity".to_string(),
            b"cve_id".to_string(),
            b"polarity".to_string(),
        ],
        vector[
            b"Vulnerability disclosure".to_string(),
            b"{data.description}".to_string(),
            b"{data.severity}/10".to_string(),
            b"{data.cve_id}".to_string(),
            b"negative".to_string(),
        ],
        std::internal::permit<Vulnerability>(),
        ctx,
    );
}

/// Issue a Vulnerability attestation about `subject`. Returns the revocation
/// cap — vulnerability attestations are typically revoked when the issue is
/// patched in the subject package.
public fun attest_vuln(
    registry: &Registry,
    subject: ID,
    severity: u8,
    cve_id: String,
    description: String,
    ctx: &mut TxContext,
): RevocationCap<Vulnerability> {
    attestation_registry::attest<Vulnerability>(
        registry,
        subject,
        Vulnerability { severity, cve_id, description },
        ctx,
    )
}

public fun severity(self: &Vulnerability): u8 { self.severity }
public fun cve_id(self: &Vulnerability): &String { &self.cve_id }
public fun description(self: &Vulnerability): &String { &self.description }
