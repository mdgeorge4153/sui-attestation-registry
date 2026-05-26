#[test_only]
module audit_example::audit_tests;

use std::type_name;
use sui::address;
use sui::test_scenario;
use attestation_registry::attestation_registry::{Self, Registry, Box};
use audit_example::audit::{Self, Audit};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }

/// Verifies that `attest_as<Audit>` invoked from this package records
/// `audit_example`'s own published address as the attester — distinct from
/// `attestation_registry`'s address and from the transaction sender.
#[test]
fun test_attest_audit_records_audit_example_package_address() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let cap = audit::attest_audit(&mut box, 9, scenario.ctx());
    let attestation_id = cap.cap_attestation_id();

    let att = attestation_registry::attestation<Audit>(&box, attestation_id);
    let audit_example_addr = address::from_ascii_bytes(
        type_name::with_original_ids<Audit>().address_string().as_bytes()
    );
    assert!(att.attester() == audit_example_addr, 0);
    assert!(att.attester() != ALICE, 0);
    assert!(att.subject() == subject, 0);

    transfer::public_transfer(cap, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}
