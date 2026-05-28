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
    EBoxDoesNotExist,
    ERevokeMismatch,
};

const ALICE: address = @0xA11CE;

/// Test-only schema. Defined here so this module is its `Permit<TestSchema>`
/// minting authority.
public struct TestSchema has store, drop {
    tag: u8,
}

fun subject_for(addr: address): ID { addr.to_id() }

/// Drive a scenario forward to the state where `Box` for `subject` is shared
/// and ready to be `take_shared`'d.
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

#[test, expected_failure(abort_code = EBoxDoesNotExist)]
fun test_attest_aborts_when_box_missing() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let cap = attestation_registry::attest<TestSchema>(
        &registry,
        subject,
        TestSchema { tag: 1 },

        scenario.ctx(),
    );
    // unreachable; satisfy the move borrow checker
    transfer::public_transfer(cap, @0x0);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun test_attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = attestation_registry::attest<TestSchema>(
        &registry,
        subject,
        TestSchema { tag: 42 },

        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 1, 0);
    let rcv: Receiving<Attestation<TestSchema>> =
        test_scenario::receiving_ticket_by_id(ids[0]);

    let a = attestation_registry::borrow_for_testing<TestSchema>(&mut box, rcv);
    assert!(a.subject() == subject, 1);
    assert!(a.data().tag == 42, 2);
    assert!(a.is_active(), 3);
    attestation_registry::put_back_for_testing(&mut box, a);

    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap1 = attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 1 },
        scenario.ctx(),
    );
    let cap2 = attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 2 },
        scenario.ctx(),
    );
    transfer::public_transfer(cap1, ALICE);
    transfer::public_transfer(cap2, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 2, 0);
    assert!(ids[0] != ids[1], 1);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_revoke_flips_is_active() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 7 },
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(registry);

    // Pre-revoke borrow: read shows active=true.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    let id = ids[0];
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(id);
    let a = attestation_registry::borrow_for_testing<TestSchema>(&mut box, rcv);
    assert!(a.is_active(), 0);
    attestation_registry::put_back_for_testing(&mut box, a);
    test_scenario::return_shared(box);

    // Revoke.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let cap = scenario.take_from_sender();
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(id);
    attestation_registry::revoke<TestSchema>(&mut box, cap, rcv, scenario.ctx());
    test_scenario::return_shared(box);

    // Post-revoke: read shows active=false.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(id);
    let a = attestation_registry::borrow_for_testing<TestSchema>(&mut box, rcv);
    assert!(!a.is_active(), 1);
    attestation_registry::put_back_for_testing(&mut box, a);
    test_scenario::return_shared(box);

    scenario.end();
}

#[test, expected_failure(abort_code = ERevokeMismatch)]
fun test_revoke_with_wrong_cap_aborts() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap_a = attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 1 },
        scenario.ctx(),
    );
    let cap_b = attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 2 },
        scenario.ctx(),
    );
    transfer::public_transfer(cap_a, ALICE);
    transfer::public_transfer(cap_b, @0x0);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    // Pair cap_a with attestation B's receiving ticket — must abort ERevokeMismatch.
    let id_b = ids[1];
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(id_b);
    let cap_a = scenario.take_from_sender();
    attestation_registry::revoke<TestSchema>(&mut box, cap_a, rcv, scenario.ctx());

    // unreachable
    test_scenario::return_shared(box);
    scenario.end();
}

// `register_display` cannot be unit-tested here: it needs the system
// `DisplayRegistry` (shared at `0xd`), and the only way to create one in tests
// is `display_registry::create_for_testing`, which is `public(package)` to the
// `sui` framework. Coverage for that flow needs integration testing on
// devnet/testnet or via the forking tool.
