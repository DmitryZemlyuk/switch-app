// Pure helpers, kept free of matter.js imports so they can be unit-tested quickly.

/** Matter device type ids that are lights; everything else with an OnOff cluster is treated as a plug. */
const LIGHT_DEVICE_TYPES = new Set([0x0100, 0x0101, 0x010c, 0x010d]);

export function kindForDeviceType(deviceType) {
  return LIGHT_DEVICE_TYPES.has(Number(deviceType)) ? "light" : "plug";
}

/** A bridged endpoint lists several device types (for example "bridged node" plus the real one): any light wins. */
export function kindForDeviceTypes(deviceTypes) {
  return (deviceTypes ?? []).some((t) => kindForDeviceType(t) === "light") ? "light" : "plug";
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
    case "humidifier.find":
    case "humidifier.disconnect":
      return { cmd: msg.cmd };
    case "humidifier.connect":
      return typeof msg.ip === "string" && typeof msg.token === "string"
        ? { cmd: msg.cmd, ip: msg.ip, token: msg.token, deviceId: Number.isInteger(msg.deviceId) ? msg.deviceId : null }
        : null;
    case "humidifier.set":
      return typeof msg.prop === "string" && msg.value !== undefined ? { cmd: msg.cmd, prop: msg.prop, value: msg.value } : null;
    case "identify":
      return typeof msg.id === "string" ? { cmd: "identify", id: msg.id } : null;
    case "unpair":
    case "refresh":
      return { cmd: msg.cmd };
    default:
      return null;
  }
}

// Matter cluster ids used for sensors.
export const CLUSTER = {
  BOOLEAN_STATE: 0x0045, OCCUPANCY: 0x0406, SWITCH: 0x003b, POWER_SOURCE: 0x002f,
  POWER_MEASUREMENT: 0x0090,
};

const SENSOR_DEVICE_TYPES = new Map([
  [0x0043, "leak"], // Water Leak Detector
  [0x0107, "motion"], // Occupancy Sensor
  [0x000f, "button"], // Generic Switch
  [0x0015, "contact"], // Contact Sensor
]);

/**
 * Decides what kind of sensor an endpoint is, from its device types first and its clusters second.
 * Returns null for endpoints that are not sensors.
 */
export function sensorTypeFor(deviceTypes, clusterIds) {
  for (const type of deviceTypes ?? []) {
    const kind = SENSOR_DEVICE_TYPES.get(Number(type));
    if (kind) return kind;
  }
  const clusters = new Set((clusterIds ?? []).map(Number));
  if (clusters.has(CLUSTER.SWITCH)) return "button";
  if (clusters.has(CLUSTER.OCCUPANCY)) return "motion";
  if (clusters.has(CLUSTER.BOOLEAN_STATE)) return "contact";
  return null;
}

/**
 * Battery info from the PowerSource cluster. `percentRaw` is in half-percent units (0–200, null when unknown),
 * `chargeLevel` is 0 ok, 1 warning, 2 critical. Returns null when the device reports neither.
 */
export function batteryFrom(percentRaw, chargeLevel) {
  const levels = ["ok", "warning", "critical"];
  const percent = typeof percentRaw === "number" && percentRaw >= 0 && percentRaw <= 200 ? Math.round(percentRaw / 2) : null;
  const level = levels[chargeLevel] ?? null;
  if (percent === null && level === null) return null;
  return { percent, level };
}

/**
 * Turns Matter Switch-cluster events into one result per gesture: single, double, long or multi (3+ presses).
 *
 * A double press arrives as initialPress, shortRelease, initialPress, shortRelease, multiPressComplete(2), and a
 * single one ends with multiPressComplete(1) – but only on buttons that support multi-press. So a release waits a
 * moment for multiPressComplete and falls back to "single" if none comes. A long press reports at once; its
 * release is ignored.
 */
export class PressClassifier {
  constructor(onGesture, { releaseWaitMs = 1200, pressFallbackMs = 2500, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
    this.onGesture = onGesture;
    this.releaseWaitMs = releaseWaitMs;
    this.pressFallbackMs = pressFallbackMs;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.pending = new Map(); // id → { timer, holding }
  }

  handle(id, eventName, data) {
    const state = this.pending.get(id);
    switch (eventName) {
      case "initialPress":
        if (state?.holding) return;
        this.#wait(id, this.pressFallbackMs);
        return;
      case "shortRelease":
        if (state?.holding) return;
        this.#wait(id, this.releaseWaitMs);
        return;
      case "longPress":
        this.#clear(id);
        this.pending.set(id, { holding: true, timer: null });
        this.onGesture(id, "long", 1);
        return;
      case "longRelease":
        this.#clear(id);
        return;
      case "multiPressComplete": {
        this.#clear(id);
        const count = Number(data?.totalNumberOfPressesCounted ?? 1) || 1;
        this.onGesture(id, count === 1 ? "single" : count === 2 ? "double" : "multi", count);
        return;
      }
      default:
        return; // multiPressOngoing, switchLatched: nothing to report
    }
  }

  #wait(id, ms) {
    this.#clear(id);
    const timer = this.setTimer(() => {
      this.pending.delete(id);
      this.onGesture(id, "single", 1);
    }, ms);
    this.pending.set(id, { holding: false, timer });
  }

  #clear(id) {
    const state = this.pending.get(id);
    if (state?.timer) this.clearTimer(state.timer);
    this.pending.delete(id);
  }
}

/** ElectricalPowerMeasurement.activePower is in milliwatts (int64, may arrive as bigint). Returns watts or null. */
export function wattsFrom(milliwatts) {
  if (milliwatts === null || milliwatts === undefined) return null;
  const value = Number(milliwatts);
  if (!Number.isFinite(value)) return null;
  return Math.round(Math.abs(value) / 100) / 10; // one decimal
}
