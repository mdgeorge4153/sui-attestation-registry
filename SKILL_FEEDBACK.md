# Sui Skill & Documentation Feedback

Feedback collected during development of the attestation registry project.

---

## 1. System dependencies are auto-resolved in newer CLI versions

**Encountered:** Adding `Sui = { git = "...", rev = "framework/testnet" }` to `Move.toml`
**Error:** `Dependency 'Sui' is a legacy system name and cannot be used.`

**Problem:** The `sui-move-project` skill documents the old pattern where Sui and
MoveStdlib must be declared as git dependencies. In CLI v1.72+ these are system
dependencies resolved automatically — declaring them is now an error.

**Suggested fix:** The `sui-move-project` skill should state that `Sui` and `MoveStdlib`
are auto-resolved system dependencies and that `[dependencies]` can be left empty (or
only list non-system deps). Note which CLI version introduced the change.

---

## 2. `sui client call` fails on functions that return non-drop values

**Encountered:** `sui client call --function attest ...`
**Error:** `UnusedValueWithoutDrop { result_idx: 0, secondary_idx: 0 }`

**Problem:** The `composable-move-functions` skill correctly recommends returning objects
rather than transferring inside the function. However, it doesn't mention that this makes
`sui client call` unusable for those functions — you must use `sui client ptb` to chain
`--assign` + `--transfer-objects`. The error message from the CLI is also opaque and
doesn't suggest using a PTB.

**Suggested fix:**
- `composable-move-functions` skill: add a note that composable functions returning
  objects cannot be invoked via `sui client call`, and show the PTB alternative.
- `ptbs` skill: mention "calling a function that returns an object" as a common use case.
- CLI improvement: the `UnusedValueWithoutDrop` error could suggest using `sui client ptb`
  with `--transfer-objects`.

---

## 3. PTB CLI syntax is non-obvious and underdocumented in skills

**Encountered:** First PTB attempt used JSON-style `["a", "b"]` for vectors and
`[Result(0)]` for result references. Both were rejected by the parser.

**Correct syntax:**
- Vector literals: `vector["a", "b"]` (not JSON arrays)
- Result binding: `--assign name` after `--move-call`, then `[name]` to reference
- String args: `'"my string"'` (single-quoted outer, double-quoted inner)

**Problem:** The PTB CLI has its own mini-language that doesn't match JSON, Move, or any
other obvious syntax. Without a quick-reference, the only way to learn it is trial and
error or `sui client ptb --help`.

**Suggested fix:** The `ptbs` skill should include a quick-reference table for CLI PTB
syntax covering vectors, result references, string arguments, and object references.

---

## 4. gRPC `getDynamicField` requires BCS-encoded name — no JSON option

**Encountered:** Building frontend lookup for the Registry's `Table<address, vector<ID>>`.
The `queries.md` skill shows `getDynamicField({ parentId, name: { type, value } })` but
the actual v2 gRPC `DynamicFieldName` type is `{ type: string; bcs: Uint8Array }`.

**Problem:** The `queries.md` skill documents dynamic field lookups with a `value` property
on the name, but the actual SDK type requires BCS-encoded bytes. The correct approach is:

```ts
import { bcs } from "@mysten/sui/bcs";
const addressBytes = bcs.Address.serialize("0x...").toBytes();
client.core.getDynamicField({
  parentId: registryId,
  name: { type: "address", bcs: addressBytes },
});
```

The response's `DynamicFieldValue` is also BCS-only — you must parse it with the
appropriate BCS type (e.g. `bcs.vector(bcs.Address).parse(result.value.bcs)`).

This is a significant usability gap compared to the JSON-RPC client's
`getDynamicFieldObject` which accepts `{ type, value }` with JSON values.

**Suggested fix:**
- `queries.md` should document the BCS requirement for `getDynamicField` with examples
  showing how to serialize common types (address, string, u64).
- Note the difference between gRPC (`bcs` field) and JSON-RPC (`value` field) APIs.
- Consider adding a `getDynamicField` example to the queries skill that shows the full
  BCS serialize → call → BCS parse roundtrip.

---

## 5. `getObjects` response contains `Error | Object` union — easy to miss

**Encountered:** TypeScript error when accessing `.json` on `getObjects` results.

**Problem:** `getObjects` returns `{ objects: (Error | Object<Include>)[] }` — each
element can be an `Error` if that object wasn't found. This is not documented in the
`queries.md` skill. The filter needed is non-obvious:

```ts
result.objects.filter((o): o is Exclude<typeof o, Error> =>
  !(o instanceof Error) && "json" in o && !!o.json
)
```

**Suggested fix:** The `queries.md` skill should note that `getObjects` (plural) can
return errors for individual objects and show the filter pattern.

---

## 6. `Published.toml` blocks fresh publish — confusing error message

**Encountered:** After redesigning the contract (incompatible struct changes), tried to
publish as a fresh package. Got: `Your package is already published. You have to manually
remove the publication entry to publish again.`

**Problem:** The `sui-publish` skill doesn't document `Published.toml` or how to handle
re-publishing scenarios. The error message does explain the fix (remove the entry), but
the skill should preemptively cover this since it's a common workflow during development:
you iterate on a design, realize you need a fresh publish rather than an upgrade, and hit
this blocker.

**Suggested fix:** The `sui-publish` skill should document:
- What `Published.toml` is and when it's auto-generated
- How to clear it for a fresh publish (remove the `[published.<env>]` section)
- When you need a fresh publish vs. an upgrade (incompatible struct changes, etc.)

---

## 7. `type_name::get<T>()` is deprecated

**Encountered:** Used `std::type_name::get<T>()` to capture the payload type name for
indexing. Build produced deprecation warning: `Renamed to 'with_defining_ids' for clarity.`

**Problem:** The skill documentation (and many tutorials) still reference `type_name::get`.
The current function is `type_name::with_defining_ids<T>()`.

**Suggested fix:** Update any skill content referencing `type_name::get` to use
`type_name::with_defining_ids`. Note the rename in the `sui-move` skill.

---

## 8. Table dynamic fields live under the Table's UID, not the parent object

**Encountered:** Frontend used the Registry's object ID as `parentId` when calling
`getDynamicField` to read Table entries. Query hung forever (no match found).

**Problem:** Sui's `Table<K, V>` stores entries as dynamic fields under the Table's own
`UID`, which is a separate object from the struct that contains the Table. To read Table
entries from the frontend, you must:

1. Read the parent object (Registry) to get the Table's ID from its JSON fields
2. Use the Table's ID as `parentId` in `getDynamicField`

This is a very easy mistake to make — nothing in the skills or docs highlights that
`Table`'s UID is different from its parent's UID. The `queries.md` skill shows
`getDynamicField` examples but doesn't cover `Table` specifically.

**Suggested fix:** The `queries.md` skill (or `sui-object-model` skill) should document
that `Table`/`ObjectTable`/`Bag` entries are dynamic fields of the collection's UID, not
the enclosing struct's UID. Include an example showing the two-step read pattern.

---

## 9. No guidance on testnet development without a browser wallet

**Encountered:** The `frontend-apps` skill assumes a browser wallet extension (Sui Wallet,
etc.) is available. In our case, development was happening in a Tart VM accessed via
Safari on the host, where no Sui wallet extension exists. We had to build a custom
keypair-based signing flow using `Ed25519Keypair` + `client.signAndExecuteTransaction`.

**Problem:** The skills only cover the wallet-based signing path. For testnet development,
direct keypair signing is a common and legitimate workflow — especially in VMs, CI, or
environments without browser extensions. The SDK supports it natively via
`client.signAndExecuteTransaction({ transaction, signer: keypair })`, but this isn't
documented in any skill.

**Suggested fix:** The `transactions.md` skill should include a "signing without a wallet"
section showing:
- How to create/import an `Ed25519Keypair`
- How to use `client.signAndExecuteTransaction` with a `signer` parameter
- A note that this is for testnet/development only (never embed keys in production apps)

---

## 10. Chaining multiple `moveCall` results in TypeScript PTBs

**Encountered:** Creating an attestation requires two `moveCall`s in one PTB: one to
construct the payload, and another to pass it to `attest_and_keep`. The pattern is:

```ts
const [payload] = tx.moveCall({
  target: `${pkg}::payloads::new_audit_report`,
  arguments: [tx.pure.string(url), tx.pure.string(auditor)],
});
tx.moveCall({
  target: `${pkg}::registry::attest_and_keep`,
  typeArguments: [`${pkg}::payloads::AuditReport`],
  arguments: [tx.object(registryId), tx.pure.address(packageId), payload],
});
```

**Problem:** This "use the return value of one moveCall as an argument to another" pattern
is fundamental to PTB composition, but the `transactions.md` skill doesn't show it. It
only covers single-moveCall PTBs and `splitCoins`/`transferObjects`. The destructuring
syntax (`const [payload] = tx.moveCall(...)`) for accessing return values isn't documented.

**Suggested fix:** The `transactions.md` or `ptbs` skill should show a multi-moveCall
example with return value passing, including the destructuring pattern and how
`typeArguments` works.

---

## 11. `tx.pure("vector<string>", values)` type syntax undocumented

**Encountered:** Needed to pass `vector<String>` arguments to a Move function. Discovered
by trial and error that `tx.pure("vector<string>", ["a", "b"])` works, while the typed
helpers only cover scalar types (`tx.pure.u64()`, `tx.pure.address()`, etc.).

**Problem:** The `transactions.md` skill documents typed pure helpers but doesn't cover
how to pass vector or other compound types. The generic `tx.pure(type, value)` overload
is the escape hatch but isn't mentioned.

**Suggested fix:** Add a quick-reference for `tx.pure` covering compound types:
- `tx.pure("vector<string>", ["a", "b"])`
- `tx.pure("vector<u8>", [1, 2, 3])`
- `tx.pure("vector<address>", ["0x..."])`

---

## 12. Skills don't cover the full "contract to frontend" development loop

**Observation:** The skills are individually well-written for their specific domains (Move
patterns, frontend setup, queries, transactions). But there's no skill that covers the
end-to-end workflow of:

1. Design a Move contract
2. Build and test it
3. Publish to testnet
4. Build a frontend that reads and writes to it
5. Handle the common pitfalls that arise at each integration point

Most of the issues in this file (4, 5, 8, 9, 10, 11) occurred at the boundary between
the Move contract and the TypeScript frontend. A "building a dApp end-to-end" skill or
tutorial that walks through a simple contract + frontend would surface these integration
issues and give a place to document patterns like BCS encoding for dynamic fields, Table
UID resolution, PTB chaining, and keypair-based testing.

---

## 13. Skills don't cover TTO / object-ownership-as-index pattern

**Encountered:** We built a registry using `Table<address, vector<ID>>` to index
attestations by package. This works but has fundamental scalability issues: every write
contends on the shared Registry object, vectors grow unboundedly (O(n) reads and
revocations), and the frontend integration required BCS-encoded dynamic field lookups
with Table UID resolution (issues #4, #8).

A better design uses **Transfer to Object (TTO)**: attestations are transferred to "box"
objects at derived addresses (one per package). The Sui runtime's object ownership graph
becomes the index. Queries use `listOwnedObjects(owner=box_address)` with native
pagination and type filtering. Writes don't touch any shared object — creating an
attestation is just `transfer::transfer(attestation, box_address)`. Revocation uses the
`Receiving<T>` pattern.

**Comparison:**

| Concern | Table + vector<ID> | Box + TTO |
|---|---|---|
| Write contention | All writes serialize on shared Registry | Writes to different packages are independent |
| Index maintenance | Manual Table updates on every write/revoke | Runtime maintains ownership graph for free |
| Vector growth | Unbounded, O(n) reads and revocations | No vectors — O(1) insert via transfer |
| Frontend queries | BCS dynamic field lookups + Table UID | `listOwnedObjects` — simple, paginated |
| On-chain readability | `attestations_for()` callable from Move | Off-chain only via RPC |
| Move complexity | Simpler — Table operations | Slightly more — `Receiving<T>`, derived addresses |

**Problem:** No skill covers TTO as an indexing/storage pattern. The `sui-object-model`
skill would be the natural home for this. The `composable-move-functions` and
`sui-move` skills focus on Table/Bag/VecMap for on-chain storage, which led directly
to a design with known scalability issues. The TTO + derived address pattern is
idiomatic Sui and avoids shared object contention entirely, but it isn't surfaced
anywhere in the skill set.

**Suggested fix:**
- The `sui-object-model` skill should document "object ownership as an index" as a
  first-class pattern, contrasting it with Table-based approaches.
- Include a worked example: derived address computation, transfer-to-object for writes,
  `Receiving<T>` for authorized operations, `listOwnedObjects` for reads.
- The `composable-move-functions` or `sui-move` skill should mention TTO as the
  preferred pattern when building registries or indexes that will see concurrent writes,
  and note that Table-based indexes create shared object bottlenecks.

---

## 14. Display V2 skill has wrong API — `borrow_mut()` doesn't exist

**Encountered:** Tried to create a Display following the skill's example:
`display_registry::borrow_mut()`. This function does not exist.

**Actual API:** `display_registry::new_with_publisher<T>(registry, publisher, ctx)` takes
a `&mut DisplayRegistry` — the shared system object at address `0xd`. The skill's example
code is fabricated.

Additionally, the skill only documents the `Publisher`-based path. The simpler V2 API
uses `internal::Permit<T>`:

```move
display_registry::new<Attestation<AuditReport>>(
    display_reg, internal::permit(), ctx,
);
```

`internal::Permit<T>` can be created by the module that defines `T` — no OTW, no
Publisher needed. This is a much simpler path for Display creation.

**Problem:** The skill's example code doesn't compile. It also doesn't mention
`internal::Permit<T>` at all, directing users to the more complex Publisher/OTW path.

**Suggested fix:**
- Fix the example code to use the actual API signatures
- Document both paths: `new_with_publisher` (requires Publisher) and `new` (requires
  `internal::Permit<T>`)
- Note that `internal::Permit<T>` is simpler when you're creating Display for your own
  types
- Document that `DisplayRegistry` is a shared system object at address `0xd`

---

## 15. Display cannot be added retroactively without Publisher

**Encountered:** Wanted to add Display to an already-published package. The Publisher
is only obtainable via `package::claim(otw, ctx)` in the `init` function. If you didn't
claim a Publisher at publish time, you can't create one later.

**Resolution:** With the `internal::Permit<T>` API (issue #14), this is no longer a
problem — you can add Display functions in a compatible upgrade without needing a
Publisher. But the skill doesn't mention this.

**Problem:** The skill implies Publisher is required for Display, which would make Display
impossible to add after publishing if you didn't plan ahead. The Permit path removes
this limitation but is undocumented.

**Suggested fix:** The Display skill should note that `internal::Permit<T>` allows
retroactive Display creation via package upgrades, without needing to have claimed a
Publisher in the original `init`.

---

## 16. Cross-package dependencies: nested packages trigger test bugs

**Encountered:** Created a dependent package (`custom-payload`) as a subdirectory inside
the parent package (`attestation_registry/examples/custom-payload`). `sui move build`
succeeded, but `sui move test` failed with "address with no value" errors. Moving the
package to a sibling directory (`packages/custom-payload`) fixed it.

**Problem:** The `sui-move-project` skill doesn't discuss multi-package workspace
layouts. Nesting packages inside each other triggers bugs in the test runner. The
recommended layout (a top-level `packages/` dir with each package as a sibling) isn't
documented.

**Suggested fix:** The `sui-move-project` skill should document:
- Recommended workspace layout for multi-package projects
- That packages should NOT be nested inside each other
- How to declare local dependencies between sibling packages
- That `[addresses]` is incompatible with new-style packages ("old-style" error)

---

## 17. `internal::Permit<T>` not documented anywhere in the skill set

**Encountered:** `internal::Permit<T>` (from `std::internal`) is a new Move stdlib
primitive that enables type-level authorization without a One-Time Witness or Publisher.
It was the key to making Display work cleanly (issue #14) and to making Display
retroactively addable (issue #15).

**Problem:** No skill mentions `internal::Permit<T>` at all. The `sui-move` skill covers
OTW and Publisher as the authorization primitives, but `Permit<T>` replaces both for
several use cases:

- Display creation (`display_registry::new` accepts `Permit<T>`)
- Type-level authorization in generic registries
- Any pattern where "only the defining module of T can call this"

**Suggested fix:** The `sui-move` skill should document `internal::Permit<T>` alongside
OTW and Publisher, with guidance on when to use which:

| Mechanism | When to use |
|---|---|
| OTW (`has drop`, module-named) | One-time setup in `init` (coin creation, etc.) |
| Publisher (`package::claim`) | Proving package authority to external systems |
| `internal::Permit<T>` | Proving you define type `T` — works in any function, not just `init` |

---

## Cross-cutting suggestions

1. The skills cover Move design patterns well but underserve the CLI workflow for calling
   the resulting contracts. A "calling your contract from the CLI" section bridging the
   `composable-move-functions` and `ptbs` skills would address issues 2 and 3 together.

2. The biggest gap is at the **Move ↔ TypeScript boundary**. Issues 4, 5, 8, 10, and 11
   all involve translating between Move types/patterns and their TypeScript SDK equivalents.
   A dedicated "Move-to-TypeScript patterns" reference would be high value.

3. Several issues (1, 6, 7) stem from **API/toolchain changes** that the skills haven't
   caught up with. A versioning or "last verified with CLI vX.Y" note on each skill would
   help identify stale content.

4. The Display skill (issue #14) contains **fabricated API calls** — `borrow_mut()` was
   never a real function. This is distinct from stale content (issues 1, 6, 7) where the
   skill was once correct. It suggests the Display skill was written from a design doc or
   RFC rather than verified against the implementation. Adding a "verified against
   sui CLI vX.Y" note per skill would catch both stale and speculative content.

5. `internal::Permit<T>` (issue #17) is a new stdlib primitive that simplifies several
   patterns across multiple skills (Display, authorization, type registries). It warrants
   coverage in the `sui-move` skill and cross-references from the Display and patterns
   skills.
