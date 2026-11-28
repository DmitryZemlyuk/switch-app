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
  assert.deepEqual(parseCommand('{"cmd":"identify","id":"6"}'), { cmd: "identify", id: "6" });
  assert.equal(parseCommand('{"cmd":"identify"}'), null);
  assert.deepEqual(parseCommand('{"cmd":"humidifier.connect","ip":"192.168.1.5","token":"t","deviceId":12}'),
    { cmd: "humidifier.connect", ip: "192.168.1.5", token: "t", deviceId: 12 });
  assert.equal(parseCommand('{"cmd":"humidifier.connect","ip":"x"}'), null);
  assert.deepEqual(parseCommand('{"cmd":"humidifier.set","prop":"target","value":60}'), { cmd: "humidifier.set", prop: "target", value: 60 });
  assert.deepEqual(parseCommand('{"cmd":"humidifier.find"}'), { cmd: "humidifier.find" });
  assert.deepEqual(parseCommand('{"cmd":"humidifier.dump"}'), { cmd: "humidifier.dump" });
  assert.equal(parseCommand("nope"), null);
  assert.equal(parseCommand('{"cmd":"rm"}'), null);
});

import { sensorTypeFor, batteryFrom, PressClassifier } from "../src/lib.mjs";

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

function fakeTimers() {
  let now = 0;
  const timers = new Map();
  let next = 1;
  return {
    setTimer: (fn, ms) => { const id = next++; timers.set(id, { fn, at: now + ms }); return id; },
    clearTimer: (id) => timers.delete(id),
    advance(ms) {
      now += ms;
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.fn(); }
    },
    get count() { return timers.size; },
  };
}

function classifier() {
  const timers = fakeTimers();
  const out = [];
  const c = new PressClassifier((id, kind, count) => out.push(`${id}:${kind}:${count}`), timers);
  return { c, out, timers };
}

test("single press with multi-press support", () => {
  const { c, out, timers } = classifier();
  c.handle("4", "initialPress");
  c.handle("4", "shortRelease");
  c.handle("4", "multiPressComplete", { totalNumberOfPressesCounted: 1 });
  timers.advance(5000);
  assert.deepEqual(out, ["4:single:1"]);
  assert.equal(timers.count, 0);
});

test("double press", () => {
  const { c, out, timers } = classifier();
  for (const e of ["initialPress", "shortRelease", "initialPress", "multiPressOngoing", "shortRelease"]) c.handle("4", e);
  timers.advance(500);
  c.handle("4", "multiPressComplete", { totalNumberOfPressesCounted: 2 });
  timers.advance(5000);
  assert.deepEqual(out, ["4:double:2"]);
});

test("triple press", () => {
  const { c, out } = classifier();
  c.handle("4", "multiPressComplete", { totalNumberOfPressesCounted: 3 });
  assert.deepEqual(out, ["4:multi:3"]);
});

test("single press without multi-press support falls back after the release", () => {
  const { c, out, timers } = classifier();
  c.handle("4", "initialPress");
  c.handle("4", "shortRelease");
  timers.advance(1199);
  assert.deepEqual(out, []);
  timers.advance(1);
  assert.deepEqual(out, ["4:single:1"]);
});

test("only initialPress still reports a press", () => {
  const { c, out, timers } = classifier();
  c.handle("4", "initialPress");
  timers.advance(2500);
  assert.deepEqual(out, ["4:single:1"]);
});

test("long press reports once and ignores its release", () => {
  const { c, out, timers } = classifier();
  c.handle("4", "initialPress");
  c.handle("4", "longPress");
  c.handle("4", "shortRelease");
  c.handle("4", "longRelease");
  timers.advance(5000);
  assert.deepEqual(out, ["4:long:1"]);
  c.handle("4", "initialPress");
  c.handle("4", "shortRelease");
  timers.advance(1200);
  assert.deepEqual(out, ["4:long:1", "4:single:1"]);
});

test("buttons are tracked separately", () => {
  const { c, out, timers } = classifier();
  c.handle("4", "initialPress");
  c.handle("5", "multiPressComplete", { totalNumberOfPressesCounted: 2 });
  timers.advance(2500);
  assert.deepEqual(out, ["5:double:2", "4:single:1"]);
});

import { wattsFrom } from "../src/lib.mjs";

test("metering", () => {
  assert.equal(wattsFrom(38240), 38.2);
  assert.equal(wattsFrom(38240n), 38.2);
  assert.equal(wattsFrom(-1500), 1.5);
  assert.equal(wattsFrom(0), 0);
  assert.equal(wattsFrom(null), null);
});
