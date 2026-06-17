#[test_only]
module attestation_registry::attestation_registry_tests;

use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{
    Self,
    Registry,
    Box,
    Attestation,
    EBoxAlreadyExists,
    EBoxRevoked,
};

const ALICE: address = @0xA11CE;

/// Test-only schema. Defined here so this module is its `Permit<TestSchema>`
/// minting authority.
public struct TestSchema has store, drop {
    tag: u8,
}

fun subject_for(addr: address): ID { addr.to_id() }

/// Create both of `subject`'s boxes (active + revoked); leaves the scenario at
/// a fresh tx.
fun setup_with_box(subject: ID): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    scenario
}

/// The object id of `subject`'s active or revoked box.
fun box_id(registry: &Registry, subject: ID, revoked: bool): ID {
    object::id_from_address(
        attestation_registry::box_address(registry, subject, revoked),
    )
}

#[test, expected_failure(abort_code = EBoxAlreadyExists)]
fun test_create_box_aborts_on_duplicate() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);
    scenario.end();
}

/// `attest` rejects the revoked box — only the active box accepts attestations.
#[test, expected_failure(abort_code = EBoxRevoked)]
fun test_attest_aborts_on_revoked_box() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let revoked = box_id(&registry, subject, true);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let revoked_box: Box = scenario.take_shared_by_id(revoked);
    attestation_registry::attest<TestSchema>(&revoked_box, TestSchema { tag: 1 }, scenario.ctx());
    test_scenario::return_shared(revoked_box);
    scenario.end();
}

#[test]
fun test_attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    attestation_registry::attest<TestSchema>(&active_box, TestSchema { tag: 42 }, scenario.ctx());
    test_scenario::return_shared(active_box);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 1, 0);
    let rcv: Receiving<Attestation<TestSchema>> =
        test_scenario::receiving_ticket_by_id(ids[0]);
    let a = attestation_registry::borrow_for_testing<TestSchema>(&mut box, rcv);
    assert!(a.subject() == subject, 1);
    assert!(a.data().tag == 42, 2);
    attestation_registry::put_back_for_testing(&mut box, a);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    attestation_registry::attest<TestSchema>(&active_box, TestSchema { tag: 1 }, scenario.ctx());
    attestation_registry::attest<TestSchema>(&active_box, TestSchema { tag: 2 }, scenario.ctx());
    test_scenario::return_shared(active_box);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 2, 0);
    assert!(ids[0] != ids[1], 1);
    test_scenario::return_shared(box);
    scenario.end();
}

/// Revocation moves the attestation out of the active box and into the
/// subject's (claimed) revoked box.
#[test]
fun test_revoke_moves_to_revoked_box() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    let revoked = box_id(&registry, subject, true);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    attestation_registry::attest<TestSchema>(&active_box, TestSchema { tag: 7 }, scenario.ctx());
    test_scenario::return_shared(active_box);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    let att_id = ids[0];
    test_scenario::return_shared(box);

    // Revoke from the active box. This module defines `TestSchema`, so it can
    // mint the `Permit<TestSchema>` the registry's `revoke` requires.
    scenario.next_tx(ALICE);
    let mut active_box: Box = scenario.take_shared_by_id(active);
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(att_id);
    attestation_registry::revoke<TestSchema>(
        &mut active_box, std::internal::permit<TestSchema>(), rcv,
    );
    test_scenario::return_shared(active_box);

    // Active box empty; the revoked box now owns the attestation.
    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
            object::id(&active_box),
        ).is_empty(),
        0,
    );
    test_scenario::return_shared(active_box);

    let revoked_box: Box = scenario.take_shared_by_id(revoked);
    let revoked_ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&revoked_box),
    );
    assert!(revoked_ids.length() == 1, 1);
    assert!(revoked_ids[0] == att_id, 2);
    test_scenario::return_shared(revoked_box);

    scenario.end();
}

// `register_display` cannot be unit-tested here: it needs the system
// `DisplayRegistry` (shared at `0xd`), and the only way to create one in tests
// is `display_registry::create_for_testing`, which is `public(package)` to the
// `sui` framework. Coverage for that flow needs integration testing on
// devnet/testnet or via the forking tool.
