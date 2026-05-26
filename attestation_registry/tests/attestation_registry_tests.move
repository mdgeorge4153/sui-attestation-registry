#[test_only]
module attestation_registry::attestation_registry_tests;

use std::type_name;
use sui::address;
use sui::clock;
use sui::test_scenario;
use attestation_registry::attestation_registry::{
    Self,
    Registry,
    Box,
    EBoxAlreadyExists,
    EWrongAttestationId,
};

const ALICE: address = @0xA11CE;

/// User-attestation payload type.
public struct Audit has store, drop {
    score: u8,
}

/// Witness/payload type for `attest_as` tests. Defined here so this test
/// module is its `Permit<TestSchema>` minting authority. The recorded
/// `attester` for `attest_as<TestSchema>` will resolve to the
/// attestation_registry package's own address.
public struct TestSchema has store, drop {
    tag: u8,
}

fun new_audit(score: u8): Audit { Audit { score } }

fun subject_for(addr: address): ID { addr.to_id() }

/// Build a fresh registry + box in a scenario for `subject`. Returns the
/// scenario already advanced into a tx where the Box can be `take_shared`.
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
fun test_create_box_happy_path() {
    let subject = subject_for(@0xDEAD);
    let scenario = setup_with_box(subject);

    let box: Box = scenario.take_shared();
    // Box's subject is denormalized — verify it round-trips.
    // (We can't read the field directly; instead, attest into it and check
    // the attestation's subject matches.)
    test_scenario::return_shared(box);

    scenario.end();
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

#[test]
fun test_attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = attestation_registry::attest<Audit>(
        &mut box,
        new_audit(8),
        scenario.ctx(),
    );
    let attestation_id = cap.cap_attestation_id();

    let clock = clock::create_for_testing(scenario.ctx());
    let att = attestation_registry::attestation<Audit>(&box, attestation_id);
    assert!(att.subject() == subject, 0);
    assert!(att.attester() == ALICE, 0);
    assert!(att.data().score == 8, 0);
    assert!(att.is_effective(&clock), 0);
    clock::destroy_for_testing(clock);

    transfer::public_transfer(cap, @0x0); // discard — test no longer needs revoke authority
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_attest_with_expiry() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = attestation_registry::attest_with_expiry<Audit>(
        &mut box,
        new_audit(5),
        2000,
        scenario.ctx(),
    );
    let attestation_id = cap.cap_attestation_id();

    let mut clock = clock::create_for_testing(scenario.ctx());
    let att = attestation_registry::attestation<Audit>(&box, attestation_id);
    clock.set_for_testing(1000);
    assert!(att.is_effective(&clock), 0);
    clock.set_for_testing(2500);
    assert!(!att.is_effective(&clock), 0);
    clock::destroy_for_testing(clock);

    transfer::public_transfer(cap, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap1 = attestation_registry::attest<Audit>(
        &mut box, new_audit(1), scenario.ctx(),
    );
    let cap2 = attestation_registry::attest<Audit>(
        &mut box, new_audit(2), scenario.ctx(),
    );
    let id1 = cap1.cap_attestation_id();
    let id2 = cap2.cap_attestation_id();
    assert!(id1 != id2, 0);

    // Both attestations exist independently with their own data.
    let a1 = attestation_registry::attestation<Audit>(&box, id1);
    let a2 = attestation_registry::attestation<Audit>(&box, id2);
    assert!(a1.data().score == 1, 0);
    assert!(a2.data().score == 2, 0);
    assert!(a1.attester() == ALICE && a2.attester() == ALICE, 0);

    transfer::public_transfer(cap1, @0x0);
    transfer::public_transfer(cap2, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_revoke_flips_is_effective() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = attestation_registry::attest<Audit>(
        &mut box, new_audit(3), scenario.ctx(),
    );
    let attestation_id = cap.cap_attestation_id();

    let clock = clock::create_for_testing(scenario.ctx());
    {
        let att = attestation_registry::attestation<Audit>(&box, attestation_id);
        assert!(att.is_effective(&clock), 0);
    };

    attestation_registry::revoke(&mut box, cap, attestation_id, scenario.ctx());

    {
        let att = attestation_registry::attestation<Audit>(&box, attestation_id);
        assert!(!att.is_effective(&clock), 0);
    };

    clock::destroy_for_testing(clock);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test, expected_failure(abort_code = EWrongAttestationId)]
fun test_revoke_with_wrong_id_aborts() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap_a = attestation_registry::attest<Audit>(
        &mut box, new_audit(1), scenario.ctx(),
    );
    let cap_b = attestation_registry::attest<Audit>(
        &mut box, new_audit(2), scenario.ctx(),
    );
    let id_b = cap_b.cap_attestation_id();

    // cap_a authorizes only its own attestation; passing id_b must abort.
    attestation_registry::revoke(&mut box, cap_a, id_b, scenario.ctx());

    // unreachable; satisfy the compiler about cap_b
    transfer::public_transfer(cap_b, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_attest_as_records_package_address() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let permit = std::internal::permit<TestSchema>();
    let cap = attestation_registry::attest_as<TestSchema>(
        permit,
        &mut box,
        TestSchema { tag: 7 },
        scenario.ctx(),
    );
    let attestation_id = cap.cap_attestation_id();

    let att = attestation_registry::attestation<TestSchema>(&box, attestation_id);
    // attester must be `TestSchema`'s package address — i.e. NOT the sender.
    let pkg = address::from_ascii_bytes(
        type_name::with_original_ids<TestSchema>().address_string().as_bytes()
    );
    assert!(att.attester() == pkg, 0);
    assert!(att.attester() != ALICE, 0);
    assert!(att.data().tag == 7, 0);

    transfer::public_transfer(cap, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_has_attestation() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let mut box: Box = scenario.take_shared();
    let cap = attestation_registry::attest<Audit>(
        &mut box, new_audit(1), scenario.ctx(),
    );
    let real_id = cap.cap_attestation_id();
    let bogus_id = subject_for(@0xBADBAD);

    assert!(attestation_registry::has_attestation<Audit>(&box, real_id), 0);
    assert!(!attestation_registry::has_attestation<Audit>(&box, bogus_id), 0);
    // A real id with the wrong T is also not a hit.
    assert!(!attestation_registry::has_attestation<TestSchema>(&box, real_id), 0);

    transfer::public_transfer(cap, @0x0);
    test_scenario::return_shared(box);
    scenario.end();
}

// `register_display` cannot be unit-tested here: it needs the system
// `DisplayRegistry` (shared at `0xd`), and the only way to create one in tests
// is `display_registry::create_for_testing`, which is `public(package)` to the
// `sui` framework. Coverage for that flow needs integration testing on
// devnet/testnet.
