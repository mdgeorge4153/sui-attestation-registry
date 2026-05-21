export interface AttestationData {
  id: string;
  type: string;
  fields: {
    package_id: string;
    attester: string;
    payload: Record<string, unknown>;
  };
}

/** Extract a short type label from the full Move type string. */
function payloadLabel(fullType: string): string {
  // fullType looks like "0xPKG::registry::Attestation<0xPKG::payloads::AuditReport>"
  const match = fullType.match(/<.*::(\w+)>$/);
  return match ? match[1] : "Unknown";
}

export function AttestationCard({
  attestation,
}: {
  attestation: AttestationData;
}) {
  const a = attestation;
  const label = payloadLabel(a.type);

  return (
    <div className="attestation-card">
      <div className="field">
        <span className="label">ID</span>
        <code>{a.id}</code>
      </div>
      <div className="field">
        <span className="label">Package</span>
        <code>{a.fields.package_id}</code>
      </div>
      <div className="field">
        <span className="label">Type</span>
        <span>{label}</span>
      </div>
      <div className="field">
        <span className="label">Attester</span>
        <code>{a.fields.attester}</code>
      </div>
      <PayloadFields payload={a.fields.payload} />
    </div>
  );
}

function PayloadFields({ payload }: { payload: Record<string, unknown> }) {
  return (
    <>
      {Object.entries(payload).map(([key, value]) => {
        if (key === "id") return null;
        const display = formatValue(value);
        return (
          <div className="field" key={key}>
            <span className="label">{key}</span>
            {isUrl(display) ? (
              <a href={display} target="_blank" rel="noopener noreferrer">
                {display}
              </a>
            ) : (
              <span>{display}</span>
            )}
          </div>
        );
      })}
    </>
  );
}

function formatValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    // Byte arrays come as number arrays — try to show as hex
    if (value.every((v) => typeof v === "number"))
      return "0x" + value.map((b) => (b as number).toString(16).padStart(2, "0")).join("");
    return JSON.stringify(value);
  }
  return String(value);
}

function isUrl(s: string): boolean {
  return s.startsWith("http://") || s.startsWith("https://");
}
