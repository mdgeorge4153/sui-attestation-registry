#[test_only]
module attestation_registry::with_expiry_tests;

use sui::clock;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use attestation_registry::with_expiry::{Self, WithExpiry};

const ALICE: address = @0xA11CE;

public struct TestSchema has store, drop {
    tag: u8,
}

fun subject_for(addr: address): ID { addr.to_id() }

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

#[test]
fun test_attest_with_expiry_happy_path() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = with_expiry::attest_with_expiry<TestSchema>(
        std::internal::permit<TestSchema>(),
        &mut box,
        TestSchema { tag: 9 },
        2000,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<
        Attestation<WithExpiry<TestSchema>>,
    >(object::id(&box));
    let rcv: Receiving<Attestation<WithExpiry<TestSchema>>> =
        test_scenario::receiving_ticket_by_id(ids[0]);

    let (a, b) = attestation_registry::borrow<WithExpiry<TestSchema>>(&mut box, rcv);
    assert!(a.subject() == subject, 0);
    assert!(a.data().inner().tag == 9, 1);
    assert!(a.is_effective(), 2);
    attestation_registry::put_back(&mut box, a, b);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_is_in_effect_active_unexpired() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = with_expiry::attest_with_expiry<TestSchema>(
        std::internal::permit<TestSchema>(),
        &mut box,
        TestSchema { tag: 1 },
        2000,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<
        Attestation<WithExpiry<TestSchema>>,
    >(object::id(&box));
    let rcv: Receiving<Attestation<WithExpiry<TestSchema>>> =
        test_scenario::receiving_ticket_by_id(ids[0]);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000);
    let (a, b) = attestation_registry::borrow<WithExpiry<TestSchema>>(&mut box, rcv);
    assert!(with_expiry::is_in_effect(&a, &clock), 0);
    attestation_registry::put_back(&mut box, a, b);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_is_in_effect_active_expired() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = with_expiry::attest_with_expiry<TestSchema>(
        std::internal::permit<TestSchema>(),
        &mut box,
        TestSchema { tag: 1 },
        2000,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<
        Attestation<WithExpiry<TestSchema>>,
    >(object::id(&box));
    let rcv: Receiving<Attestation<WithExpiry<TestSchema>>> =
        test_scenario::receiving_ticket_by_id(ids[0]);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(2500);
    let (a, b) = attestation_registry::borrow<WithExpiry<TestSchema>>(&mut box, rcv);
    assert!(!with_expiry::is_in_effect(&a, &clock), 0);
    attestation_registry::put_back(&mut box, a, b);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_is_in_effect_revoked() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = with_expiry::attest_with_expiry<TestSchema>(
        std::internal::permit<TestSchema>(),
        &mut box,
        TestSchema { tag: 1 },
        2000,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(box);

    // Revoke.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<
        Attestation<WithExpiry<TestSchema>>,
    >(object::id(&box));
    let id = ids[0];
    let rcv: Receiving<Attestation<WithExpiry<TestSchema>>> =
        test_scenario::receiving_ticket_by_id(id);
    let cap = scenario.take_from_sender();
    let (a, b) = attestation_registry::borrow<WithExpiry<TestSchema>>(&mut box, rcv);
    attestation_registry::revoke<WithExpiry<TestSchema>>(&mut box, a, cap, b, scenario.ctx());
    test_scenario::return_shared(box);

    // is_in_effect → false even though clock is before expiration.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let rcv: Receiving<Attestation<WithExpiry<TestSchema>>> =
        test_scenario::receiving_ticket_by_id(id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(500);
    let (a, b) = attestation_registry::borrow<WithExpiry<TestSchema>>(&mut box, rcv);
    assert!(!with_expiry::is_in_effect(&a, &clock), 0);
    attestation_registry::put_back(&mut box, a, b);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(box);
    scenario.end();
}
