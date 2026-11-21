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
