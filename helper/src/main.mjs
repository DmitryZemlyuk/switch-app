// Matter controller helper for the Switch app.
//
// The app starts this process with the bundled Node runtime (storage folder in SWITCH_STORAGE_DIR)
// and talks to it with JSON lines:
//   stdin  (app → helper): {"cmd":"pair","code":"…"} | {"cmd":"set","id":"3","on":true} | {"cmd":"unpair"} | {"cmd":"refresh"}
//   stdout (helper → app): {"ev":"state","state":"…"} | {"ev":"devices","devices":[…]} | {"ev":"update","id":"3","on":true}
//                          {"ev":"error","code":"…","message":"…"}
// All matter.js logging goes to stderr so stdout stays a clean protocol channel.

import { createInterface } from "node:readline";
import { Environment, Logger } from "@matter/main";
import { ManualPairingCodeCodec, QrPairingCodeCodec } from "@matter/main/types";
import { GeneralCommissioning, OnOff, BridgedDeviceBasicInformation } from "@matter/main/clusters";
import { CommissioningController } from "@project-chip/matter.js";
import { kindForDeviceType, normalizePairingCode, connectionStateName, parseCommand } from "./lib.mjs";

Logger.destinations.default.write = (text) => process.stderr.write(text + "\n");
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

async function collectDevices() {
  if (!node) return;
  const found = [];
  const seen = new Set();
  switches.clear();

  const walk = async (ep) => {
    const number = ep.getNumber();
    if (seen.has(number)) return;
    seen.add(number);
    const onOff = ep.getClusterClient(OnOff.Cluster);
    if (onOff && number !== 0) {
      const id = String(number);
      switches.set(id, onOff);
      let on = false;
      let label;
      let reachable = true;
      try { on = !!(await onOff.getOnOffAttribute(false)); } catch {}
      const bridged = ep.getClusterClient(BridgedDeviceBasicInformation.Cluster);
      if (bridged) {
        try { label = await bridged.getNodeLabelAttribute(false); } catch {}
        try { if (!label) label = await bridged.getProductNameAttribute(false); } catch {}
        try { reachable = (await bridged.getReachableAttribute(false)) !== false; } catch {}
      }
      found.push({ id, label: label || "", on, reachable, kind: kindForDeviceType(ep.deviceType) });
    }
    for (const child of ep.getChildEndpoints()) await walk(child);
  };

  for (const device of node.getDevices()) await walk(device);
  found.sort((a, b) => Number(a.id) - Number(b.id));
  send({ ev: "devices", devices: found });
}

async function attachNode(nodeId) {
  node = await controller.getNode(nodeId);
  node.events.stateChanged.on((state) => send({ ev: "state", state: connectionStateName(state) }));
  node.events.initialized.on(() => collectDevices().catch(reportError("devices")));
  node.events.structureChanged.on(() => collectDevices().catch(reportError("devices")));
  node.events.attributeChanged.on(({ path, value }) => {
    if (path.clusterId === OnOff.Cluster.id && path.attributeName === "onOff") {
      send({ ev: "update", id: String(path.endpointId), on: !!value });
    } else if (path.clusterId === BridgedDeviceBasicInformation.Cluster.id &&
               (path.attributeName === "nodeLabel" || path.attributeName === "reachable")) {
      collectDevices().catch(reportError("devices"));
    }
  });
  node.events.decommissioned.on(() => {
    node = undefined;
    switches.clear();
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
