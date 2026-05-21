/// A third-party attestation payload type: software license certification.
///
/// Demonstrates that anyone can define custom payload types in their own
/// package and use them with the attestation registry.
module custom_payload::license;

use std::string::String;

/// Certifies that a package is released under a specific license.
public struct LicenseCertification has store, drop {
    /// SPDX license identifier (e.g. "Apache-2.0", "MIT").
    spdx_id: String,
    /// URL to the license text or NOTICE file.
    license_url: String,
}

/// Construct a `LicenseCertification` payload.
public fun new(spdx_id: String, license_url: String): LicenseCertification {
    LicenseCertification { spdx_id, license_url }
}

/// SPDX identifier.
public fun spdx_id(l: &LicenseCertification): &String { &l.spdx_id }

/// License URL.
public fun license_url(l: &LicenseCertification): &String { &l.license_url }
