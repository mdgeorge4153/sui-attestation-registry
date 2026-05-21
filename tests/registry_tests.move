#[test_only]
module attestation_registry::registry_tests;

use attestation_registry::registry;
use attestation_registry::payloads::{
    Self,
    AuditReport,
    SourceVerification,
};

#[test]
fun test_attest_and_read() {
    let mut ctx = tx_context::dummy();
    let mut registry = registry::new_for_testing(&mut ctx);

    let pkg = @0xABC;
    let payload = payloads::new_audit_report(
        b"https://example.com/report.pdf".to_string(),
        b"Acme Security".to_string(),
    );
    let attestation = registry.attest(pkg, payload, &mut ctx);

    // Check accessors.
    assert!(attestation.package_id() == pkg);
    assert!(attestation.attester() == ctx.sender());
    assert!(attestation.payload().audit_report_url()
        == &b"https://example.com/report.pdf".to_string());
    assert!(attestation.payload().audit_report_auditor()
        == &b"Acme Security".to_string());

    // Check both indexes.
    let all_ids = registry.attestations_for(pkg);
    assert!(all_ids.length() == 1);
    let typed_ids = registry.attestations_for_type<AuditReport>(pkg);
    assert!(typed_ids.length() == 1);
    // No SourceVerification attestations yet.
    let sv_ids = registry.attestations_for_type<SourceVerification>(pkg);
    assert!(sv_ids.length() == 0);

    // Revoke.
    registry.revoke(attestation);
    assert!(registry.attestations_for(pkg).length() == 0);
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 0);

    registry.destroy_for_testing();
}

#[test]
fun test_multiple_types() {
    let mut ctx = tx_context::dummy();
    let mut registry = registry::new_for_testing(&mut ctx);
    let pkg = @0xABC;

    let audit = registry.attest(
        pkg,
        payloads::new_audit_report(
            b"https://example.com/report.pdf".to_string(),
            b"Acme".to_string(),
        ),
        &mut ctx,
    );
    let source = registry.attest(
        pkg,
        payloads::new_source_verification(
            b"deadbeef",
            b"https://github.com/example/repo".to_string(),
            b"abc123".to_string(),
        ),
        &mut ctx,
    );

    // All attestations for the package.
    assert!(registry.attestations_for(pkg).length() == 2);
    // Filtered by type.
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 1);
    assert!(registry.attestations_for_type<SourceVerification>(pkg).length() == 1);

    // Revoke audit, source remains.
    registry.revoke(audit);
    assert!(registry.attestations_for(pkg).length() == 1);
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 0);
    assert!(registry.attestations_for_type<SourceVerification>(pkg).length() == 1);

    registry.revoke(source);
    assert!(registry.attestations_for(pkg).length() == 0);

    registry.destroy_for_testing();
}

#[test]
fun test_multiple_attestations_same_type() {
    let mut ctx = tx_context::dummy();
    let mut registry = registry::new_for_testing(&mut ctx);
    let pkg = @0xABC;

    let a1 = registry.attest(
        pkg,
        payloads::new_audit_report(
            b"https://example.com/report1.pdf".to_string(),
            b"Acme".to_string(),
        ),
        &mut ctx,
    );
    let a2 = registry.attest(
        pkg,
        payloads::new_audit_report(
            b"https://example.com/report2.pdf".to_string(),
            b"Other Firm".to_string(),
        ),
        &mut ctx,
    );

    assert!(registry.attestations_for(pkg).length() == 2);
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 2);

    registry.revoke(a1);
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 1);

    registry.revoke(a2);
    assert!(registry.attestations_for_type<AuditReport>(pkg).length() == 0);

    registry.destroy_for_testing();
}
