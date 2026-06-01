module attestation_registry::attestation_registry;

use std::internal::Permit;
use std::string::String;
use std::type_name;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};
use sui::event;
use sui::transfer::Receiving;

#[error(code = 0)]
const EBoxAlreadyExists: vector<u8> =
    b"A Box already exists for this subject";

#[error(code = 1)]
const EBoxDoesNotExist: vector<u8> =
    b"No Box exists for this subject; call create_box first";

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Per-subject child of `Registry`. Owns every attestation about its subject
/// via transfer-to-object; the Attestation lives at the Box's address.
///
/// The Box's address is `derived_object::derive_address(registry, subject)`,
/// so off-chain consumers can compute it from `(registry_id, subject_id)` and
/// enumerate via `getOwnedObjects(box_addr, filter={StructType: ...})` —
/// native server-side type filtering, no client-side post-filter.
public struct Box has key {
    id: UID,
    subject: ID,
}

/// Typed attestation about `subject`. Stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`, no `drop`). External
/// callers have no way to obtain an `Attestation<T>` by value (no public
/// function returns one), and even if they did they couldn't transfer it
/// (`public_transfer` requires `store`), wrap it in another struct (Move
/// forbids storing `key` objects inside other objects), or drop it. The only
/// disposition of an `Attestation<T>` is through this module's `revoke`,
/// which receives it internally and re-transfers it to the owning Box.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
    active: bool,
}

/// Emitted by every `attest` call. Indexers filter by the phantom `T`
/// (which becomes part of the event's fully-qualified Move type — RPC
/// supports filtering by struct-type) and key by `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted by every `revoke` call. Same shape as `Attested` for symmetry.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

/// Frozen wrapper that locks a `DisplayCap<Attestation<T>>` so the Display
/// template registered by `register_display` is permanently immutable. The
/// `cap` field is module-private; freezing makes the wrapper itself
/// immovable and unsharable; together those make the cap permanently
/// inaccessible without the @0x0 transfer anti-pattern.
public struct DisplayLock<T: store> has key {
    id: UID,
    cap: display_registry::DisplayCap<Attestation<T>>,
}

// === Setup ===

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Create the per-subject `Box`. Aborts `EBoxAlreadyExists` if one already
/// exists for this `subject`.
public fun create_box(registry: &mut Registry, subject: ID) {
    assert!(!derived_object::exists(&registry.id, subject), EBoxAlreadyExists);
    let id = derived_object::claim(&mut registry.id, subject);
    transfer::share_object(Box { id, subject });
}

// === Accessors ===

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// `true` iff `self` has not been revoked. Time-based effectiveness (e.g.
/// expiration) is expressed via Display conventions, not via this field —
/// see CONVENTIONS.md.
public fun is_active<T: store>(self: &Attestation<T>): bool { self.active }

/// Original-publish address of `T`'s defining package. Useful for on-chain
/// trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address { type_name::original_id<T>() }

// === Attest / Revoke ===

/// Attest about `subject` (under `registry`) with `data`. The caller must
/// produce a `T` value, which Move's construction rules already restrict to
/// `T`'s defining package — that's the property `attester_of<T>()` records.
/// Aborts `EBoxDoesNotExist` if no Box exists for this subject (call
/// `create_box` first). Returns the new attestation's `ID`, the one piece a
/// schema can't otherwise recover (the object goes straight to the Box), so
/// it can build whatever revocation authority it wants — a bearer cap bound
/// to this id, an admin-gated revoke, or none at all.
public fun attest<T: store>(
    registry: &Registry,
    subject: ID,
    data: T,
    ctx: &mut TxContext,
): ID {
    assert!(derived_object::exists(&registry.id, subject), EBoxDoesNotExist);
    let box_addr = derived_object::derive_address(object::id(registry), subject);
    let attestation = Attestation<T> {
        id: object::new(ctx),
        subject,
        data,
        active: true,
    };
    let attestation_id = object::id(&attestation);
    event::emit(Attested<T> { subject });
    transfer::transfer(attestation, box_addr);
    attestation_id
}

/// Revoke the attestation referenced by `rcv`: flip its `active` flag to
/// false and re-transfer it to the owning Box. `rcv` alone identifies which
/// attestation, so no id check is needed here.
///
/// Gated by `Permit<T>`: only `T`'s defining module can mint one, so the
/// *policy* for who may revoke (a bearer cap, an admin cap, a multisig, …)
/// lives in that module, while the state transition and `Revoked<T>` event
/// stay uniform here — the same split as `register_display`.
public fun revoke<T: store>(
    box: &mut Box,
    _: Permit<T>,
    rcv: Receiving<Attestation<T>>,
) {
    let mut a = transfer::receive(&mut box.id, rcv);
    a.active = false;
    event::emit(Revoked<T> { subject: a.subject });
    transfer::transfer(a, box.id.to_address());
}

// === Display ===

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>` (only `T`'s defining module can mint
/// it); one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`, `{active}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// One field is appended automatically: `active` rendering `true`/`false`.
/// Schemas adopting cross-cutting conventions (`expires_at`, `requires`,
/// etc. — see CONVENTIONS.md) include those fields themselves.
#[allow(lint(freeze_wrapped))]
public fun register_display<T: store>(
    display_registry: &mut DisplayRegistry,
    mut fields: vector<String>,
    mut values: vector<String>,
    _: Permit<T>,
    ctx: &mut TxContext,
) {
    fields.push_back(b"active".to_string());
    values.push_back(b"{active}".to_string());

    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        std::internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display_registry::share(display);

    // Lock the DisplayCap inside a frozen wrapper so the template is
    // permanently immutable. The wrapper struct's `cap` field is private to
    // this module, so external code can't extract the cap; freezing makes
    // the wrapper itself immovable; together that's equivalent in effect to
    // destroying the cap (which the framework doesn't expose a way to do).
    transfer::freeze_object(DisplayLock<T> { id: object::new(ctx), cap });
}

// === Test seam ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Test-only mirror of the `borrow`/`put_back` pattern documented in
/// docs/future-extensions.md. Production callers can't reach this, so the
/// hot-potato discipline isn't required here — tests just receive,
/// inspect, and put back manually.
#[test_only]
public fun borrow_for_testing<T: store>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): Attestation<T> {
    transfer::receive(&mut box.id, rcv)
}

#[test_only]
public fun put_back_for_testing<T: store>(box: &mut Box, a: Attestation<T>) {
    transfer::transfer(a, box.id.to_address());
}
