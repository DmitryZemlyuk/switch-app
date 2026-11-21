// Pure helpers, kept free of matter.js imports so they can be unit-tested quickly.

/** Matter device type ids that are lights; everything else with an OnOff cluster is treated as a plug. */
const LIGHT_DEVICE_TYPES = new Set([0x0100, 0x0101, 0x010c, 0x010d]);

export function kindForDeviceType(deviceType) {
  return LIGHT_DEVICE_TYPES.has(Number(deviceType)) ? "light" : "plug";
}

/**
 * Normalises what the user typed into the pairing field.
 * Returns { type: "qr", value } for "MT:..." strings, { type: "manual", value } for 11 or 21 digits,
 * or null when the input can't be a Matter pairing code.
 */
export function normalizePairingCode(input) {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (/^MT:[0-9A-Z.\-]+$/i.test(trimmed)) return { type: "qr", value: trimmed.toUpperCase() };
  const digits = trimmed.replace(/[\s\-]/g, "");
  if (/^\d{11}$/.test(digits) || /^\d{21}$/.test(digits)) return { type: "manual", value: digits };
  return null;
}

/** Maps matter.js NodeStates (0 connected, 1 disconnected, 2 reconnecting, 3 waiting for discovery). */
export function connectionStateName(nodeState) {
  switch (nodeState) {
    case 0: return "connected";
    case 2: return "reconnecting";
    case 3: return "searching";
    default: return "disconnected";
  }
}

/** Parses one protocol line from the app. Returns null for anything malformed. */
export function parseCommand(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return null;
  }
  if (!msg || typeof msg !== "object" || typeof msg.cmd !== "string") return null;
  switch (msg.cmd) {
    case "pair":
      return typeof msg.code === "string" ? { cmd: "pair", code: msg.code } : null;
    case "set":
      return typeof msg.id === "string" && typeof msg.on === "boolean" ? { cmd: "set", id: msg.id, on: msg.on } : null;
    case "unpair":
    case "refresh":
      return { cmd: msg.cmd };
    default:
      return null;
  }
}
