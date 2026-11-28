import { test } from "node:test";
import assert from "node:assert/strict";
import dgram from "node:dgram";
import {
  buildPacket, parsePacket, parseHeader, tokenFromHello, isValidToken, MiioDevice,
} from "../src/miio.mjs";
import { waterFrom, stateFrom, valueFor, CA4 } from "../src/humidifier.mjs";

const TOKEN_HEX = "00112233445566778899aabbccddeeff";
const TOKEN = Buffer.from(TOKEN_HEX, "hex");

test("packet round trip", () => {
  const packet = buildPacket(TOKEN, 0x1234abcd, 4242, '{"id":7,"method":"miIO.info","params":[]}');
  const header = parseHeader(packet);
  assert.equal(header.deviceId, 0x1234abcd);
  assert.equal(header.stamp, 4242);
  assert.equal(header.length, packet.length);
  assert.deepEqual(parsePacket(TOKEN, packet), { id: 7, method: "miIO.info", params: [] });
  // A different token fails the checksum instead of returning garbage.
  assert.equal(parsePacket(Buffer.alloc(16, 1), packet), null);
});

test("token from hello reply", () => {
  const hello = Buffer.alloc(32);
  hello.writeUInt16BE(0x2131, 0);
  hello.writeUInt16BE(32, 2);
  Buffer.from(TOKEN_HEX, "hex").copy(hello, 16);
  assert.equal(tokenFromHello(hello), TOKEN_HEX);
  hello.fill(0xff, 16);
  assert.equal(tokenFromHello(hello), null);
  hello.fill(0x00, 16);
  assert.equal(tokenFromHello(hello), null);
  assert.equal(tokenFromHello(Buffer.alloc(10)), null);
});

test("token validation", () => {
  assert.ok(isValidToken(TOKEN_HEX));
  assert.ok(isValidToken(" " + TOKEN_HEX.toUpperCase() + " "));
  assert.ok(!isValidToken("123"));
  assert.ok(!isValidToken(undefined));
});

test("water level", () => {
  assert.deepEqual(waterFrom(120), { percent: 100, state: "ok" });
  assert.deepEqual(waterFrom(125), { percent: 100, state: "ok" });
  assert.deepEqual(waterFrom(60), { percent: 50, state: "ok" });
  assert.deepEqual(waterFrom(24), { percent: 20, state: "low" });
  assert.deepEqual(waterFrom(0), { percent: 0, state: "low" });
  assert.deepEqual(waterFrom(127), { percent: null, state: "open" });
  assert.deepEqual(waterFrom(undefined), { percent: null, state: "ok" });
});

test("state from properties", () => {
  const state = stateFrom([
    { did: "power", code: 0, value: true },
    { did: "fault", code: 0, value: 0 },
    { did: "mode", code: 0, value: 2 },
    { did: "target", code: 0, value: 65 },
    { did: "water", code: 0, value: 90 },
    { did: "temperature", code: 0, value: 22.46 },
    { did: "humidity", code: -4001, value: 0 },
  ]);
  assert.deepEqual(state, {
    power: true, mode: 2, target: 65, humidity: null, temperature: 22.5,
    waterPercent: 75, water: "ok", fault: 0,
  });
});

test("values from the app are validated", () => {
  assert.equal(valueFor("target", 80), 80);
  assert.equal(valueFor("target", 81), undefined);
  assert.equal(valueFor("target", 29), undefined);
  assert.equal(valueFor("mode", 3), 3);
  assert.equal(valueFor("mode", 4), undefined);
  assert.equal(valueFor("power", false), false);
  assert.equal(valueFor("power", "on"), undefined);
  assert.equal(valueFor("dry", true), undefined);
});

/** A fake ca4 on localhost: answers hello and get/set_properties like the real device. */
function fakeDevice() {
  const props = { power: true, mode: 0, target: 55, water: 100, temperature: 21.3, humidity: 41, fault: 0 };
  const server = dgram.createSocket("udp4");
  const seen = [];
  server.on("message", (msg, rinfo) => {
    if (msg.length === 32) {
      const hello = Buffer.alloc(32);
      hello.writeUInt16BE(0x2131, 0);
      hello.writeUInt16BE(32, 2);
      hello.writeUInt32BE(0xabc, 8);
      hello.writeUInt32BE(1000, 12);
      TOKEN.copy(hello, 16);
      server.send(hello, rinfo.port, rinfo.address);
      return;
    }
    const request = parsePacket(TOKEN, msg);
    seen.push(request.method);
    let result;
    if (request.method === "get_properties") {
      result = request.params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0, value: props[p.did] }));
    } else if (request.method === "set_properties") {
      for (const p of request.params) props[p.did] = p.value;
      result = request.params.map((p) => ({ did: p.did, siid: p.siid, piid: p.piid, code: 0 }));
    }
    const reply = buildPacket(TOKEN, 0xabc, 1001, JSON.stringify({ id: request.id, result }));
    server.send(reply, rinfo.port, rinfo.address);
  });
  return new Promise((resolve) => server.bind(0, "127.0.0.1", () => resolve({ server, props, seen })));
}

test("talks to a device: handshake, read, write", async () => {
  const { server, props, seen } = await fakeDevice();
  const { port } = server.address();
  const device = new MiioDevice("127.0.0.1", TOKEN_HEX);
  // Point this test device at the fake server's port.
  const realSend = dgram.Socket.prototype.send;
  dgram.Socket.prototype.send = function (msg, p, host, cb) {
    return realSend.call(this, msg, p === 54321 ? port : p, host, cb);
  };
  try {
    const read = await device.send("get_properties", ["power", "target"].map((did) => ({ did, ...CA4[did] })));
    assert.deepEqual(read.map((r) => r.value), [true, 55]);
    await device.send("set_properties", [{ did: "target", ...CA4.target, value: 70 }]);
    assert.equal(props.target, 70);
    assert.deepEqual(seen, ["get_properties", "set_properties"]);
  } finally {
    dgram.Socket.prototype.send = realSend;
    device.close();
    server.close();
  }
});
