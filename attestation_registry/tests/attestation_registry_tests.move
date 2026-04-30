#[test_only]
module attestation_registry::attestation_registry_tests;

use sui::clock;
use sui::test_scenario;
use attestation_registry::attestation_registry::{
    Self,
    Registry,
    Attestation,
    EAttestationAlreadyExists,
    ENotAttester,
    EAlreadyRevoked,
    EDisplayAlreadyRegistered,
};

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

public struct Audit has store, drop {
    score: u8,
}

fun new_audit(score: u8): Audit { Audit { score } }

fun subject_for(addr: address): ID { addr.to_id() }

#[test]
fun test_attest_and_read() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::attest<Audit>(
        &mut registry,
        subject_for(@0xDEAD),
        new_audit(8),
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let att: Attestation<Audit> = scenario.take_shared();
    let clock = clock::create_for_testing(scenario.ctx());
    assert!(att.subject() == subject_for(@0xDEAD), 0);
    assert!(att.attester() == ALICE, 0);
    assert!(att.data().score == 8, 0);
    assert!(att.is_effective(&clock), 0);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(att);

    scenario.end();
}

#[test]
fun test_attest_with_expiry() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::attest_with_expiry<Audit>(
        &mut registry,
        subject_for(@0xDEAD),
        new_audit(5),
        2000,
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let att: Attestation<Audit> = scenario.take_shared();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000);
    assert!(att.is_effective(&clock), 0);
    clock.set_for_testing(2500);
    assert!(!att.is_effective(&clock), 0);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(att);

    scenario.end();
}

#[test, expected_failure(abort_code = EAttestationAlreadyExists)]
fun test_double_attest_aborts() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    let subject = subject_for(@0xDEAD);
    attestation_registry::attest<Audit>(&mut registry, subject, new_audit(1), scenario.ctx());
    attestation_registry::attest<Audit>(&mut registry, subject, new_audit(2), scenario.ctx());
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun test_revoke_makes_ineffective() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::attest<Audit>(
        &mut registry,
        subject_for(@0xDEAD),
        new_audit(3),
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut att: Attestation<Audit> = scenario.take_shared();
    let clock = clock::create_for_testing(scenario.ctx());
    assert!(att.is_effective(&clock), 0);
    attestation_registry::revoke(&mut att, scenario.ctx());
    assert!(!att.is_effective(&clock), 0);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(att);

    scenario.end();
}

#[test, expected_failure(abort_code = ENotAttester)]
fun test_revoke_non_attester_aborts() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::attest<Audit>(
        &mut registry,
        subject_for(@0xDEAD),
        new_audit(3),
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(BOB);
    let mut att: Attestation<Audit> = scenario.take_shared();
    attestation_registry::revoke(&mut att, scenario.ctx());
    test_scenario::return_shared(att);
    scenario.end();
}

#[test, expected_failure(abort_code = EAlreadyRevoked)]
fun test_double_revoke_aborts() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::attest<Audit>(
        &mut registry,
        subject_for(@0xDEAD),
        new_audit(3),
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut att: Attestation<Audit> = scenario.take_shared();
    attestation_registry::revoke(&mut att, scenario.ctx());
    attestation_registry::revoke(&mut att, scenario.ctx());
    test_scenario::return_shared(att);
    scenario.end();
}

#[test]
fun test_register_display_happy() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::register_display<Audit>(
        internal::permit<Audit>(),
        &mut registry,
        vector[],
        vector[],
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = EDisplayAlreadyRegistered)]
fun test_double_register_display_aborts() {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::register_display<Audit>(
        internal::permit<Audit>(),
        &mut registry,
        vector[],
        vector[],
        scenario.ctx(),
    );
    attestation_registry::register_display<Audit>(
        internal::permit<Audit>(),
        &mut registry,
        vector[],
        vector[],
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);
    scenario.end();
}
