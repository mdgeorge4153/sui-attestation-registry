#[test_only]
module audit_example::audit_tests;

use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use audit_example::audit::{Self, Audit};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }

/// Verifies the cross-package attest flow: `audit_example::attest_audit`
/// produces an attestation accessible via `with_attestation!`, and the
/// attester resolution (`attester_of<Audit>`) returns audit_example's
/// package address — distinct from `attestation_registry`'s.
#[test]
fun test_attest_audit_cross_package() {
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
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(ids[0]);

    attestation_registry::with_attestation!<Audit>(
        &mut box,
        rcv,
        |a| {
            assert!(a.subject() == subject, 0);
            assert!(a.data().score() == 9, 1);
            assert!(a.is_effective(), 2);
        },
    );

    // attester_of<Audit> must resolve to audit_example's package address,
    // not attestation_registry's. We don't have a hardcoded address to
    // compare against, but we can compare against attester_of for a type
    // defined in attestation_registry: they must differ.
    let audit_pkg = attestation_registry::attester_of<Audit>();
    let registry_pkg = attestation_registry::attester_of<Registry>();
    assert!(audit_pkg != registry_pkg, 3);

    test_scenario::return_shared(box);
    scenario.end();
}
