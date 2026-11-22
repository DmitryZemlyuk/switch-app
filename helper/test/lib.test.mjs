import { test } from "node:test";
import assert from "node:assert/strict";
import { kindForDeviceType, kindForDeviceTypes, normalizePairingCode, connectionStateName, parseCommand } from "../src/lib.mjs";

test("pairing codes", () => {
  assert.deepEqual(normalizePairingCode("3497-011-2332"), { type: "manual", value: "34970112332" });
  assert.deepEqual(normalizePairingCode(" 3497 0112 332 "), { type: "manual", value: "34970112332" });
  assert.deepEqual(normalizePairingCode("mt:y.k9042c00kc6ka00"), { type: "qr", value: "MT:Y.K9042C00KC6KA00" });
  assert.equal(normalizePairingCode("1234"), null);
  assert.equal(normalizePairingCode(""), null);
  assert.equal(normalizePairingCode(undefined), null);
});

test("device kinds", () => {
  assert.equal(kindForDeviceType(0x010a), "plug");
  assert.equal(kindForDeviceType(0x0100), "light");
  assert.equal(kindForDeviceType(undefined), "plug");
  assert.equal(kindForDeviceTypes([0x0013, 0x0100]), "light");
  assert.equal(kindForDeviceTypes([0x0013, 0x010a]), "plug");
  assert.equal(kindForDeviceTypes(undefined), "plug");
});

test("states", () => {
  assert.equal(connectionStateName(0), "connected");
  assert.equal(connectionStateName(1), "disconnected");
  assert.equal(connectionStateName(2), "reconnecting");
  assert.equal(connectionStateName(3), "searching");
});

test("commands", () => {
  assert.deepEqual(parseCommand('{"cmd":"set","id":"3","on":true}'), { cmd: "set", id: "3", on: true });
  assert.equal(parseCommand('{"cmd":"set","id":3,"on":true}'), null);
  assert.deepEqual(parseCommand('{"cmd":"pair","code":"x"}'), { cmd: "pair", code: "x" });
  assert.deepEqual(parseCommand('{"cmd":"unpair"}'), { cmd: "unpair" });
  assert.equal(parseCommand("nope"), null);
  assert.equal(parseCommand('{"cmd":"rm"}'), null);
});

import { sensorTypeFor, batteryFrom, PRESS_EVENTS } from "../src/lib.mjs";

test("sensor types", () => {
  assert.equal(sensorTypeFor([0x0013, 0x0043], [0x0045]), "leak");
  assert.equal(sensorTypeFor([0x0107], []), "motion");
  assert.equal(sensorTypeFor([0x000f], [0x003b]), "button");
  assert.equal(sensorTypeFor([0x0013], [0x003b]), "button");
  assert.equal(sensorTypeFor([0x0013], [0x0406]), "motion");
  assert.equal(sensorTypeFor([0x0013], [0x0045]), "contact");
  assert.equal(sensorTypeFor([0x000e], [0x001d]), null);
  assert.equal(sensorTypeFor(undefined, undefined), null);
});

test("battery", () => {
  assert.deepEqual(batteryFrom(174, 0), { percent: 87, level: "ok" });
  assert.deepEqual(batteryFrom(null, 2), { percent: null, level: "critical" });
  assert.deepEqual(batteryFrom(200, undefined), { percent: 100, level: null });
  assert.equal(batteryFrom(null, undefined), null);
  assert.equal(batteryFrom(255, 7), null);
});

test("press events", () => {
  assert.ok(PRESS_EVENTS.has("multiPressComplete"));
  assert.ok(!PRESS_EVENTS.has("longRelease"));
});

import { wattsFrom } from "../src/lib.mjs";

test("metering", () => {
  assert.equal(wattsFrom(38240), 38.2);
  assert.equal(wattsFrom(38240n), 38.2);
  assert.equal(wattsFrom(-1500), 1.5);
  assert.equal(wattsFrom(0), 0);
  assert.equal(wattsFrom(null), null);
});
