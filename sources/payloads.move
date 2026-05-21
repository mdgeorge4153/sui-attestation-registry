/// Example attestation payload types.
///
/// These are provided as common defaults. Anyone can define additional payload
/// types in their own packages and use them with the registry.
module attestation_registry::payloads;

use std::string::String;

/// An audit report for a package.
public struct AuditReport has store, drop {
    /// URL pointing to the full audit report.
    url: String,
    /// Name or address of the auditing firm.
    auditor: String,
}

/// Construct an `AuditReport` payload.
public fun new_audit_report(url: String, auditor: String): AuditReport {
    AuditReport { url, auditor }
}

/// URL of the audit report.
public fun audit_report_url(r: &AuditReport): &String { &r.url }

/// Auditor name.
public fun audit_report_auditor(r: &AuditReport): &String { &r.auditor }

/// A verification that published bytecode matches a known source revision.
public struct SourceVerification has store, drop {
    /// Hash of the source code (e.g. SHA-256 of the repo at a commit).
    source_hash: vector<u8>,
    /// URL of the source repository.
    repo_url: String,
    /// Git commit or tag that was verified.
    revision: String,
}

/// Construct a `SourceVerification` payload.
public fun new_source_verification(
    source_hash: vector<u8>,
    repo_url: String,
    revision: String,
): SourceVerification {
    SourceVerification { source_hash, repo_url, revision }
}

/// Source hash bytes.
public fun source_hash(v: &SourceVerification): &vector<u8> { &v.source_hash }

/// Repository URL.
public fun repo_url(v: &SourceVerification): &String { &v.repo_url }

/// Git revision.
public fun revision(v: &SourceVerification): &String { &v.revision }
