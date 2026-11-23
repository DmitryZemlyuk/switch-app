// Matter controller helper for the Switch app.
//
// The app starts this process with the Mac's own Node.js (storage folder in SWITCH_STORAGE_DIR)
// and talks to it with JSON lines:
//   stdin  (app → helper): {"cmd":"pair","code":"…"} | {"cmd":"set","id":"3","on":true} | {"cmd":"unpair"} | {"cmd":"refresh"}
//   stdout (helper → app): {"ev":"state","state":"…"} | {"ev":"devices","devices":[…]} | {"ev":"update","id":"3","on":true}
//                          {"ev":"sensors","sensors":[…]} | {"ev":"press","id":"7"}
//                          {"ev":"power","id":"8","watts":38.2}
//                          {"ev":"error","code":"…","message":"…"}
// All matter.js logging goes to stderr so stdout stays a clean protocol channel.

import { createInterface } from "node:readline";
import { Environment, Logger } from "@matter/main";
import { ManualPairingCodeCodec, QrPairingCodeCodec } from "@matter/main/types";
import {
  GeneralCommissioning, OnOff, BridgedDeviceBasicInformation, BooleanState, OccupancySensing, PowerSource,
  ElectricalPowerMeasurement,
} from "@matter/main/clusters";
import { CommissioningController } from "@project-chip/matter.js";
import {
  kindForDeviceTypes, normalizePairingCode, connectionStateName, parseCommand,
  sensorTypeFor, batteryFrom, CLUSTER, PRESS_EVENTS, wattsFrom,
} from "./lib.mjs";

// Short network drops (Mac asleep, Wi-Fi switching) make every UDP socket report these; matter.js recovers by itself.
const NETWORK_NOISE = /recvmsg (EHOSTUNREACH|ENETUNREACH|ENETDOWN|EADDRNOTAVAIL)/;
Logger.destinations.default.write = (text) => {
  if (NETWORK_NOISE.test(text)) return;
  process.stderr.write(text + "\n");
};

// Node warns that node:sqlite (matter.js storage) is experimental on every start: keep other warnings only.
process.removeAllListeners("warning");
process.on("warning", (warning) => {
  if (warning.name === "ExperimentalWarning" && /sqlite/i.test(warning.message)) return;
  process.stderr.write(`${warning.name}: ${warning.message}\n`);
});
Logger.level = process.env.SWITCH_DEBUG ? "debug" : "notice";

// Passed via the environment: matter.js reads its own settings from command-line arguments.
const storagePath = process.env.SWITCH_STORAGE_DIR;
if (!storagePath) {
  process.stderr.write("SWITCH_STORAGE_DIR is not set\n");
  process.exit(2);
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

const environment = Environment.default;
environment.vars.set("storage.path", storagePath);

const controller = new CommissioningController({
  environment: { environment, id: "switch-controller" },
  autoConnect: false,
  adminFabricLabel: "Switch",
});

let node; // PairedNode of the hub
let busy = false; // pairing or unpairing in progress
const switches = new Map(); // endpoint id → OnOff cluster client

let structureLogged = false;

async function readLabel(ep) {
  const bridged = ep.getClusterClient(BridgedDeviceBasicInformation.Cluster);
  let label;
  let reachable = true;
  if (bridged) {
    try { label = await bridged.getNodeLabelAttribute(false); } catch {}
    try { if (!label) label = await bridged.getProductNameAttribute(false); } catch {}
    try { reachable = (await bridged.getReachableAttribute(false)) !== false; } catch {}
  }
  return { label: label || "", reachable };
}

async function readBattery(ep) {
  const power = ep.getClusterClient(PowerSource.Cluster);
  if (!power) return null;
  let percentRaw = null;
  let level;
  try { percentRaw = await power.getBatPercentRemainingAttribute?.(false); } catch {}
  try { level = await power.getBatChargeLevelAttribute?.(false); } catch {}
  return batteryFrom(percentRaw, level);
}

const METER_FIELDS = ["voltage", "rmsVoltage", "activeCurrent", "rmsCurrent", "frequency", "powerFactor", "activePower"];

/** One diagnostic log line: which values the plug's power meter really answers (read from the plug itself). */
async function describeMeter(ep) {
  const meter = ep.getClusterClient(ElectricalPowerMeasurement.Cluster);
  if (!meter) return `  endpoint ${ep.getNumber()}: no power meter`;
  const parts = [];
  try {
    const list = await meter.getAttributeListAttribute?.(true);
    if (list) parts.push(`attributeList [${list.map((id) => "0x" + Number(id).toString(16).padStart(4, "0")).join(", ")}]`);
  } catch (error) {
    parts.push(`attributeList ? (${error?.message ?? error})`);
  }
  for (const field of METER_FIELDS) {
    const getter = meter[`get${field[0].toUpperCase()}${field.slice(1)}Attribute`];
    if (typeof getter !== "function") continue;
    try {
      const value = await getter.call(meter, true);
      parts.push(`${field}=${value === null || value === undefined ? "null" : String(value)}`);
    } catch (error) {
      parts.push(`${field}=unsupported`);
    }
  }
  return `  endpoint ${ep.getNumber()}: ${parts.join(" ")}`;
}

/** Watts for a plug with a power meter (0 when the meter has no value yet), null for one without. */
async function readWatts(ep) {
  const meter = ep.getClusterClient(ElectricalPowerMeasurement.Cluster);
  if (!meter) return null;
  try {
    return wattsFrom(await meter.getActivePowerAttribute(false)) ?? 0;
  } catch {
    return 0;
  }
}

async function readActive(ep, type) {
  try {
    if (type === "motion") {
      const occupancy = await ep.getClusterClient(OccupancySensing.Cluster)?.getOccupancyAttribute(false);
      return !!occupancy?.occupied;
    }
    if (type === "leak" || type === "contact") {
      return !!(await ep.getClusterClient(BooleanState.Cluster)?.getStateValueAttribute(false));
    }
  } catch {}
  return false;
}

async function collectDevices() {
  if (!node) return;
  const plugs = [];
  const sensors = [];
  const seen = new Set();
  switches.clear();
  const logLines = [];
  const meterEndpoints = [];

  const walk = async (ep) => {
    const number = ep.getNumber();
    if (seen.has(number)) return;
    seen.add(number);
    let types = [ep.deviceType];
    try { types = types.concat(ep.getDeviceTypes().map((t) => t.code)); } catch {}
    let clusterIds = [];
    try { clusterIds = ep.getAllClusterClients().map((c) => c.id); } catch {}
    if (!structureLogged) {
      const hex = (n) => "0x" + Number(n).toString(16).padStart(4, "0");
      logLines.push(`  endpoint ${number}: types [${[...new Set(types.map(Number))].map(hex).join(", ")}] clusters [${clusterIds.map(hex).join(", ")}]`);
    }

    const onOff = ep.getClusterClient(OnOff.Cluster);
    if (onOff && number !== 0) {
      const id = String(number);
      switches.set(id, onOff);
      let on = false;
      try { on = !!(await onOff.getOnOffAttribute(false)); } catch {}
      const { label, reachable } = await readLabel(ep);
      const watts = await readWatts(ep);
      plugs.push({ id, label, on, reachable, kind: kindForDeviceTypes(types), watts });
      if (!structureLogged) meterEndpoints.push(ep);
    } else if (number !== 0) {
      const type = sensorTypeFor(types, clusterIds);
      if (type) {
        const { label, reachable } = await readLabel(ep);
        sensors.push({
          id: String(number),
          label,
          reachable,
          type,
          active: await readActive(ep, type),
          battery: await readBattery(ep),
        });
      }
    }
    for (const child of ep.getChildEndpoints()) await walk(child);
  };

  for (const device of node.getDevices()) await walk(device);
  if (!structureLogged && seen.size > 0) {
    structureLogged = true;
    process.stderr.write(`hub structure (${seen.size} endpoints):\n${logLines.join("\n")}\n`);
    // Asking the plugs directly takes a moment: do it after the tiles are out.
    if (meterEndpoints.length > 0) {
      (async () => {
        const lines = [];
        for (const ep of meterEndpoints) lines.push(await describeMeter(ep));
        process.stderr.write(`power meters:\n${lines.join("\n")}\n`);
      })().catch((error) => process.stderr.write(`power meter check failed: ${error?.message ?? error}\n`));
    }
  }
  const byId = (a, b) => Number(a.id) - Number(b.id);
  send({ ev: "devices", devices: plugs.sort(byId) });
  send({ ev: "sensors", sensors: sensors.sort(byId) });
}

// Many attribute reports arrive in bursts: collect once after they settle.
let collectTimer;
function scheduleCollect() {
  clearTimeout(collectTimer);
  collectTimer = setTimeout(() => collectDevices().catch(reportError("devices")), 250);
}

async function attachNode(nodeId) {
  node = await controller.getNode(nodeId);
  node.events.stateChanged.on((state) => send({ ev: "state", state: connectionStateName(state) }));
  node.events.initialized.on(() => scheduleCollect());
  node.events.structureChanged.on(() => {
    structureLogged = false;
    scheduleCollect();
  });
  node.events.attributeChanged.on(({ path, value }) => {
    if (path.clusterId === OnOff.Cluster.id && path.attributeName === "onOff") {
      send({ ev: "update", id: String(path.endpointId), on: !!value });
    } else if (path.clusterId === BridgedDeviceBasicInformation.Cluster.id &&
               (path.attributeName === "nodeLabel" || path.attributeName === "reachable")) {
      scheduleCollect();
    } else if (path.clusterId === CLUSTER.POWER_MEASUREMENT && path.attributeName === "activePower") {
      // Some plugs report null instead of 0 when switched off.
      send({ ev: "power", id: String(path.endpointId), watts: wattsFrom(value) ?? 0 });
    } else if (path.clusterId === CLUSTER.BOOLEAN_STATE || path.clusterId === CLUSTER.OCCUPANCY ||
               (path.clusterId === CLUSTER.POWER_SOURCE && String(path.attributeName).startsWith("bat"))) {
      scheduleCollect();
    }
  });
  node.events.eventTriggered.on(({ path }) => {
    if (path.clusterId === CLUSTER.SWITCH && PRESS_EVENTS.has(path.eventName)) {
      send({ ev: "press", id: String(path.endpointId) });
    }
  });
  node.events.decommissioned.on(() => {
    node = undefined;
    switches.clear();
    send({ ev: "devices", devices: [] });
    send({ ev: "sensors", sensors: [] });
    send({ ev: "state", state: "unpaired" });
  });
  // After commissioning the node is usually connected already; after a restart it is not.
  if (node.isConnected) {
    send({ ev: "state", state: connectionStateName(node.connectionState) });
  } else {
    send({ ev: "state", state: "searching" });
    node.connect();
  }
  if (node.initialized) await collectDevices();
}

function reportError(code) {
  return (error) => send({ ev: "error", code, message: String(error?.message ?? error) });
}

async function pair(rawCode) {
  if (busy) return;
  if (node) {
    send({ ev: "error", code: "already_paired", message: "Already paired" });
    return;
  }
  const code = normalizePairingCode(rawCode);
  if (!code) {
    send({ ev: "error", code: "bad_code", message: "Not a Matter pairing code" });
    return;
  }
  let passcode;
  let identifierData;
  try {
    if (code.type === "qr") {
      const data = QrPairingCodeCodec.decode(code.value)[0];
      passcode = data.passcode;
      identifierData = { longDiscriminator: data.discriminator };
    } else {
      const data = ManualPairingCodeCodec.decode(code.value);
      passcode = data.passcode;
      identifierData = { shortDiscriminator: data.shortDiscriminator };
    }
  } catch (error) {
    send({ ev: "error", code: "bad_code", message: String(error?.message ?? error) });
    return;
  }

  busy = true;
  send({ ev: "state", state: "pairing" });
  try {
    const nodeId = await controller.commissionNode({
      commissioning: {
        regulatoryLocation: GeneralCommissioning.RegulatoryLocationType.IndoorOutdoor,
        regulatoryCountryCode: "XX",
      },
      discovery: { identifierData, discoveryCapabilities: { onIpNetwork: true } },
      passcode,
    });
    await attachNode(nodeId);
  } catch (error) {
    send({ ev: "error", code: "pair_failed", message: String(error?.message ?? error) });
    send({ ev: "state", state: "unpaired" });
  } finally {
    busy = false;
  }
}

async function unpair() {
  if (busy) return;
  busy = true;
  try {
    for (const nodeId of controller.getCommissionedNodes()) {
      try {
        await controller.removeNode(nodeId, true);
      } catch (error) {
        // The hub may be offline; forget it locally anyway.
        process.stderr.write(`removeNode failed: ${error?.message ?? error}\n`);
        try { await controller.removeNode(nodeId, false); } catch {}
      }
    }
  } finally {
    node = undefined;
    switches.clear();
    busy = false;
    send({ ev: "devices", devices: [] });
    send({ ev: "sensors", sensors: [] });
    send({ ev: "state", state: "unpaired" });
  }
}

async function setSwitch(id, on) {
  const client = switches.get(id);
  if (!client) {
    send({ ev: "error", code: "unknown_device", message: `No switch ${id}` });
    return;
  }
  try {
    if (on) await client.on();
    else await client.off();
    send({ ev: "update", id, on });
  } catch (error) {
    send({ ev: "error", code: "set_failed", message: String(error?.message ?? error) });
    // Tell the app the real state so the tile flips back.
    try { send({ ev: "update", id, on: !!(await client.getOnOffAttribute(false)) }); } catch {}
  }
}

async function handle(line) {
  const cmd = parseCommand(line);
  if (!cmd) return;
  switch (cmd.cmd) {
    case "pair": return pair(cmd.code);
    case "unpair": return unpair();
    case "set": return setSwitch(cmd.id, cmd.on);
    case "refresh":
      if (node) {
        send({ ev: "state", state: connectionStateName(node.connectionState) });
        return collectDevices();
      }
      send({ ev: "state", state: "unpaired" });
  }
}

let closing = false;
async function shutdown(exitCode = 0) {
  if (closing) return;
  closing = true;
  try { await controller.close(); } catch {}
  process.exit(exitCode);
}

process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));

try {
  await controller.start();
} catch (error) {
  send({ ev: "error", code: "start_failed", message: String(error?.message ?? error) });
  process.exit(1);
}

const nodes = controller.getCommissionedNodes();
if (nodes.length > 0) {
  attachNode(nodes[0]).catch(reportError("connect_failed"));
} else {
  send({ ev: "state", state: "unpaired" });
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  handle(line).catch(reportError("internal"));
});
// The app closed our stdin: it quit or is restarting us.
rl.on("close", () => shutdown(0));
