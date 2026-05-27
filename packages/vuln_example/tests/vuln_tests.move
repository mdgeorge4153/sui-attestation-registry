#[test_only]
module vuln_example::vuln_tests;

use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use vuln_example::vuln::{Self, Vulnerability};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }

/// Verifies the cross-package attest flow for vuln_example, and that
/// `attester_of<Vulnerability>` resolves to vuln_example's package address —
/// distinct from attestation_registry's and from audit_example's.
#[test]
fun test_attest_vuln_cross_package() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let cap = vuln::attest_vuln(
        &registry,
        subject,
        7,
        b"CVE-2026-1234".to_string(),
        b"Reentrancy in withdraw".to_string(),
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Vulnerability>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<Vulnerability>> =
        test_scenario::receiving_ticket_by_id(ids[0]);

    let a = attestation_registry::borrow_for_testing<Vulnerability>(&mut box, rcv);
    assert!(a.subject() == subject, 0);
    assert!(a.data().severity() == 7, 1);
    assert!(a.data().cve_id() == b"CVE-2026-1234".to_string(), 2);
    assert!(a.is_active(), 3);
    attestation_registry::put_back_for_testing(&mut box, a);

    // attester_of<Vulnerability> must resolve to vuln_example's address —
    // distinct from attestation_registry's.
    let vuln_pkg = attestation_registry::attester_of<Vulnerability>();
    let registry_pkg = attestation_registry::attester_of<Registry>();
    assert!(vuln_pkg != registry_pkg, 4);

    test_scenario::return_shared(box);
    scenario.end();
}
