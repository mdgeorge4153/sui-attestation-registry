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

## Cross-cutting suggestion

The skills cover Move design patterns well but underserve the CLI workflow for calling
the resulting contracts. A "calling your contract from the CLI" section bridging the
`composable-move-functions` and `ptbs` skills would address issues 2 and 3 together.
