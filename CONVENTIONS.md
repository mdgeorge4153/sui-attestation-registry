# Display Conventions

`attestation_registry` keeps its core type minimal — `Attestation<T>` has a
`subject`, `data: T`, and an `active: bool`. Cross-cutting behaviors that
schemas might want (expiration, dependency relationships, etc.) are expressed
as **Display field conventions** rather than additional Move types. Off-chain
consumers (wallets, indexers, the `ts/` library) recognize these conventional
field names and apply the corresponding semantics when evaluating trust.

The benefit of conventions-over-functors is composability: a schema can adopt
zero, one, or many of these by including the corresponding fields in its
`register_display` call. Combining them doesn't require nested type wrappers
(`WithExpiry<WithRequires<Audit<OtterSec>>>`) — the schema just lists the
fields it surfaces, and conventions stack naturally.

## Base effectiveness

All convention-based effectiveness rules below are **conjunctive with the
registry's own revocation state**: an attestation is never effective when its
on-chain `active` field is `false`. The conventions below add further
conditions on top of that base; revocation alone is sufficient to make an
attestation ineffective regardless of how its convention fields render.

## Conventions

### `expires_at`

An attestation is **effective** only when current time is before the value of
its `expires_at` Display field. Absence of the field means the attestation
never expires.

The field's rendered type is a timestamp. Recommended template form using
Display V2's `:ts` transform on a `u64` field:

```move
fields.push_back(b"expires_at".to_string());
values.push_back(b"{data.expires_at_ms:ts}".to_string());
```

This requires the schema's `T` to include an `expires_at_ms: u64` field. The
schema decides how that field is populated (always-present, sentinel for
"never expires," etc.).

Off-chain evaluator pseudocode:

```ts
const expiresAt = parseTimestamp(attestation.display?.expires_at);
const expired = expiresAt !== null && Date.now() >= expiresAt;
```

### `requires`

An attestation is **effective** only if every attestation referenced in its
`requires` Display field is itself effective. Effectiveness is evaluated
transitively across the `requires` graph.

The field's rendered type is a list of attestation object IDs. Recommended
template:

```move
fields.push_back(b"requires".to_string());
values.push_back(b"{data.requires:json}".to_string());
```

where the schema's `T` includes a `requires: vector<ID>` field.

Off-chain evaluator pseudocode:

```ts
async function isEffective(att, visited = new Set()): Promise<boolean> {
  if (!att.active) return false;
  if (isExpired(att)) return false;
  if (visited.has(att.id)) return false; // cycle: treat as ineffective
  visited.add(att.id);
  for (const reqId of att.display?.requires ?? []) {
    const req = await fetchAttestation(reqId);
    if (!await isEffective(req, visited)) return false;
  }
  return true;
}
```

Cycle handling: a cycle in the `requires` graph is treated as ineffective.
Schemas that need acyclicity should enforce it at issue time (e.g., by
checking that none of the targets transitively reference the new attestation
before issuing).

### `polarity`

Distinguishes **positive** attestations (an assertion of good standing — e.g.
an audit) from **negative** ones (an assertion of a problem — e.g. a
vulnerability disclosure). The field renders the literal string `positive` or
`negative`; absence defaults to `positive`.

```move
fields.push_back(b"polarity".to_string());
values.push_back(b"positive".to_string()); // or b"negative"
```

Polarity is a fixed property of the schema, so the template hardcodes it
rather than reading `data`.

Consumers use it to render the two kinds differently and — for negatives — to
**propagate**: a negative attestation that is effective on a package is
surfaced on that package's *dependents* (transitively, via the dependency
graph), so a vulnerability in a dependency shows up when browsing anything
that depends on it. Propagation is the negative-polarity dual of `requires`:
`requires` is an explicit, per-attestation link pulling toward the dependency;
propagation is implicit and graph-derived, pushing toward dependents. A
revoked or expired negative attestation does not propagate.

## Presentation fields

These don't affect effectiveness; they're how an attestation renders. They
reuse the **standard Sui Display field names**, so an `Attestation<T>` shows up
sensibly in any Display-aware tool (wallets, explorers), not just bespoke
consumers.

- **`name`** — short title (e.g. `b"Audit attestation"`).
- **`description`** — human-readable summary; may interpolate `data`
  (e.g. `b"Score: {data.score}/100"`).
- **`image_url`** — an image for the attestation: a grade badge, severity
  glyph, report thumbnail, etc.
- **`link`** — a URL to the full artifact (the audit report, the CVE record).

```move
fields.push_back(b"link".to_string());
values.push_back(b"{data.report_url}".to_string());
```

**Security note.** `image_url` and `link` are *attester-supplied content*, so:

- They must never be used to derive **identity** — which attester issued an
  attestation is established by `T`'s defining package (the bytecode-anchored
  attester), not by anything in these fields. A consumer rendering an attester
  badge must source it from its own trust config, never from `image_url`.
- A consumer should treat the URLs defensively: require `https`, and prefer
  constraining the host to the attester's known domains so one (whitelisted)
  attester can't render another's branding or point at unrelated hosts.

## Adding a new convention

A new convention is an additive change: define the field name, its rendered
type, the effectiveness rule, and document it here. Existing schemas continue
to work; schemas adopting the new convention add the field to their
`register_display` call.

If a convention requires on-chain enforcement (e.g., a verifier contract that
needs `is_effective` to apply expiration without an off-chain hop), it should
graduate from this document into a typed Move helper. None of the conventions
above are at that point yet.
