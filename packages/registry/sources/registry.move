/// An on-chain attestation registry for associating typed metadata with Sui
/// packages.
///
/// The registry is generic over the attestation payload type `T`. Anyone can
/// define new payload structs (e.g. `AuditReport`, `SourceVerification`) in
/// their own modules and register attestations using them. A shared `Registry`
/// object indexes attestations by package ID and by (package, payload type) so
/// consumers can efficiently query attestations.
module attestation_registry::registry;

use std::string::String;
use std::type_name;
use sui::table::{Self, Table};
use sui::event;
use sui::display_registry;
use attestation_registry::payloads;

// ─── Types ──────────────────────────────────────────────────────────

/// Shared index mapping package IDs to their attestation IDs.
public struct Registry has key {
    id: UID,
    /// package address → all attestation IDs
    attestations: Table<address, vector<ID>>,
    /// (package address, payload type name) → attestation IDs
    attestations_by_type: Table<PackageTypeKey, vector<ID>>,
}

/// Compound key for the type-filtered index.
public struct PackageTypeKey has copy, drop, store {
    package_id: address,
    attestation_type: String,
}

/// A typed attestation about a Sui package. Owned by the attester.
///
/// `T` is the payload — e.g. an `AuditReport` or `SourceVerification`.
public struct Attestation<T: store + drop> has key, store {
    id: UID,
    /// The package being attested.
    package_id: address,
    /// The address that created this attestation.
    attester: address,
    /// The type-specific payload.
    payload: T,
}

// ─── Events ─────────────────────────────────────────────────────────

/// Emitted when a new attestation is created.
public struct AttestationCreated has copy, drop {
    attestation_id: ID,
    package_id: address,
    attester: address,
    attestation_type: String,
}

/// Emitted when an attestation is revoked (destroyed) by its owner.
public struct AttestationRevoked has copy, drop {
    attestation_id: ID,
    package_id: address,
    attester: address,
    attestation_type: String,
}

// ─── Init ───────────────────────────────────────────────────────────

/// Create and share the singleton registry on publish.
fun init(ctx: &mut TxContext) {
    let registry = Registry {
        id: object::new(ctx),
        attestations: table::new(ctx),
        attestations_by_type: table::new(ctx),
    };
    transfer::share_object(registry);
}

// ─── Display setup ─────────────────────────────────────────────────

/// Create and share a Display for Attestation<AuditReport>.
/// Uses `internal::Permit` — no Publisher or OTW needed.
entry fun setup_audit_report_display(
    display_reg: &mut display_registry::DisplayRegistry,
    ctx: &mut TxContext,
) {
    let (mut d, cap) =
        display_registry::new<Attestation<payloads::AuditReport>>(
            display_reg, internal::permit(), ctx,
        );
    display_registry::set(
        &mut d, &cap,
        b"name".to_string(), b"Audit Report Attestation".to_string(),
    );
    display_registry::set(
        &mut d, &cap,
        b"description".to_string(),
        b"Audit report for package {package_id} by {payload.auditor}".to_string(),
    );
    display_registry::set(
        &mut d, &cap,
        b"link".to_string(), b"{payload.url}".to_string(),
    );
    display_registry::share(d);
    transfer::public_transfer(cap, ctx.sender());
}

/// Create and share a Display for Attestation<SourceVerification>.
entry fun setup_source_verification_display(
    display_reg: &mut display_registry::DisplayRegistry,
    ctx: &mut TxContext,
) {
    let (mut d, cap) =
        display_registry::new<Attestation<payloads::SourceVerification>>(
            display_reg, internal::permit(), ctx,
        );
    display_registry::set(
        &mut d, &cap,
        b"name".to_string(), b"Source Verification Attestation".to_string(),
    );
    display_registry::set(
        &mut d, &cap,
        b"description".to_string(),
        b"Source verification for package {package_id} at revision {payload.revision}".to_string(),
    );
    display_registry::set(
        &mut d, &cap,
        b"link".to_string(), b"{payload.repo_url}".to_string(),
    );
    display_registry::share(d);
    transfer::public_transfer(cap, ctx.sender());
}

// ─── Public entry points ────────────────────────────────────────────

/// Create a new attestation and register it in both indexes.
///
/// `registry` — the shared registry.
/// `package_id` — the address of the package being attested.
/// `payload` — the type-specific attestation data.
public fun attest<T: store + drop>(
    registry: &mut Registry,
    package_id: address,
    payload: T,
    ctx: &mut TxContext,
): Attestation<T> {
    let attester = ctx.sender();
    let attestation = Attestation {
        id: object::new(ctx),
        package_id,
        attester,
        payload,
    };

    let attestation_id = object::id(&attestation);
    let attestation_type = type_name::with_defining_ids<T>().into_string().to_string();

    // Update the package index.
    if (!registry.attestations.contains(package_id)) {
        registry.attestations.add(package_id, vector[attestation_id]);
    } else {
        registry.attestations[package_id].push_back(attestation_id);
    };

    // Update the (package, type) index.
    let key = PackageTypeKey { package_id, attestation_type };
    if (!registry.attestations_by_type.contains(key)) {
        registry.attestations_by_type.add(key, vector[attestation_id]);
    } else {
        registry.attestations_by_type[key].push_back(attestation_id);
    };

    event::emit(AttestationCreated {
        attestation_id,
        package_id,
        attester,
        attestation_type,
    });

    attestation
}

/// Convenience entry wrapper: create an attestation and transfer to sender.
///
/// `T` must have `store + drop`. Cannot be called from other modules via
/// PTB composition — use `attest` for that.
entry fun attest_and_keep<T: store + drop>(
    registry: &mut Registry,
    package_id: address,
    payload: T,
    ctx: &mut TxContext,
) {
    let attestation = attest(registry, package_id, payload, ctx);
    transfer::transfer(attestation, ctx.sender());
}

/// Revoke (destroy) an attestation and remove it from both indexes.
///
/// Only the owner can call this since `Attestation` is passed by value.
///
/// `registry` — the shared registry to update.
/// `attestation` — the attestation to revoke.
public fun revoke<T: store + drop>(
    registry: &mut Registry,
    attestation: Attestation<T>,
) {
    let Attestation { id, package_id, attester, payload: _ } = attestation;
    let attestation_id = id.to_inner();
    let attestation_type = type_name::with_defining_ids<T>().into_string().to_string();

    // Remove from the package index.
    remove_from_index(&mut registry.attestations, package_id, attestation_id);

    // Remove from the (package, type) index.
    let key = PackageTypeKey { package_id, attestation_type };
    remove_from_typed_index(
        &mut registry.attestations_by_type, key, attestation_id,
    );

    event::emit(AttestationRevoked {
        attestation_id,
        package_id,
        attester,
        attestation_type,
    });

    id.delete();
}

// ─── Read accessors ─────────────────────────────────────────────────

/// Return all attestation IDs for `package_id`, or empty if none.
public fun attestations_for(
    registry: &Registry, package_id: address,
): vector<ID> {
    if (registry.attestations.contains(package_id)) {
        registry.attestations[package_id]
    } else {
        vector[]
    }
}

/// Return attestation IDs for `package_id` with payload type `T`.
public fun attestations_for_type<T: store + drop>(
    registry: &Registry, package_id: address,
): vector<ID> {
    let key = PackageTypeKey {
        package_id,
        attestation_type: type_name::with_defining_ids<T>().into_string().to_string(),
    };
    if (registry.attestations_by_type.contains(key)) {
        registry.attestations_by_type[key]
    } else {
        vector[]
    }
}

/// The package this attestation is about.
public fun package_id<T: store + drop>(a: &Attestation<T>): address {
    a.package_id
}

/// Who created this attestation.
public fun attester<T: store + drop>(a: &Attestation<T>): address {
    a.attester
}

/// The type-specific payload.
public fun payload<T: store + drop>(a: &Attestation<T>): &T {
    &a.payload
}

// ─── Internal helpers ───────────────────────────────────────────────

/// Remove `attestation_id` from the vector stored under `key` in `table`.
fun remove_from_index(
    table: &mut Table<address, vector<ID>>,
    key: address,
    attestation_id: ID,
) {
    if (table.contains(key)) {
        let ids = &mut table[key];
        let (found, idx) = ids.index_of(&attestation_id);
        if (found) {
            ids.remove(idx);
        };
    };
}

/// Remove `attestation_id` from the vector stored under `key` in the typed
/// index table.
fun remove_from_typed_index(
    table: &mut Table<PackageTypeKey, vector<ID>>,
    key: PackageTypeKey,
    attestation_id: ID,
) {
    if (table.contains(key)) {
        let ids = &mut table[key];
        let (found, idx) = ids.index_of(&attestation_id);
        if (found) {
            ids.remove(idx);
        };
    };
}

// ─── Test helpers ───────────────────────────────────────────────────

#[test_only]
/// Create a Registry for unit tests (bypasses `init`).
public fun new_for_testing(ctx: &mut TxContext): Registry {
    Registry {
        id: object::new(ctx),
        attestations: table::new(ctx),
        attestations_by_type: table::new(ctx),
    }
}

#[test_only]
/// Destroy a test registry.
public fun destroy_for_testing(registry: Registry) {
    let Registry { id, attestations, attestations_by_type } = registry;
    attestations.drop();
    attestations_by_type.drop();
    id.delete();
}
