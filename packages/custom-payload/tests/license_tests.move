#[test_only]
module custom_payload::license_tests;

use attestation_registry::registry;
use custom_payload::license;

#[test]
fun test_custom_payload_attestation() {
    let mut ctx = tx_context::dummy();
    let mut registry = registry::new_for_testing(&mut ctx);
    let pkg = @0xABC;

    let payload = license::new(
        b"Apache-2.0".to_string(),
        b"https://example.com/LICENSE".to_string(),
    );
    let attestation = registry.attest(pkg, payload, &mut ctx);

    assert!(attestation.package_id() == pkg);
    assert!(attestation.payload().spdx_id() == &b"Apache-2.0".to_string());

    // Check it shows up in the index.
    assert!(registry.attestations_for(pkg).length() == 1);

    registry.revoke(attestation);
    assert!(registry.attestations_for(pkg).length() == 0);

    registry.destroy_for_testing();
}
