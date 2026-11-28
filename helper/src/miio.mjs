// Minimal local miIO / MIoT client (UDP 54321) for Xiaomi Wi-Fi devices.
// Packet layout: 32-byte header (magic 0x2131, length, unknown, device id, stamp, checksum) + AES-128-CBC payload.

import { createCipheriv, createDecipheriv, createHash } from "node:crypto";
import dgram from "node:dgram";

export const MIIO_PORT = 54321;
const HELLO = Buffer.from("21310020" + "ff".repeat(28), "hex");

const md5 = (...parts) => createHash("md5").update(Buffer.concat(parts)).digest();

function keys(token) {
  const key = md5(token);
  const iv = md5(key, token);
  return { key, iv };
}

export function encrypt(token, plain) {
  const { key, iv } = keys(token);
  const cipher = createCipheriv("aes-128-cbc", key, iv);
  return Buffer.concat([cipher.update(plain), cipher.final()]);
}

export function decrypt(token, data) {
  const { key, iv } = keys(token);
  const decipher = createDecipheriv("aes-128-cbc", key, iv);
  return Buffer.concat([decipher.update(data), decipher.final()]);
}

/** Header fields of any miIO packet. */
export function parseHeader(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 32 || buf.readUInt16BE(0) !== 0x2131) return null;
  return {
    length: buf.readUInt16BE(2),
    deviceId: buf.readUInt32BE(8),
    stamp: buf.readUInt32BE(12),
    checksum: buf.subarray(16, 32),
  };
}

/**
 * The token a hello reply carries in its checksum field. Stock firmware sends ff…ff or 00…00 there once set up;
 * firmware that exposes the token locally sends the real one.
 */
export function tokenFromHello(buf) {
  const header = parseHeader(buf);
  if (!header || buf.length !== 32) return null;
  const hex = header.checksum.toString("hex");
  if (/^(f{32}|0{32})$/.test(hex)) return null;
  return hex;
}

export function buildPacket(token, deviceId, stamp, payload) {
  const body = encrypt(token, Buffer.from(payload, "utf8"));
  const header = Buffer.alloc(32);
  header.writeUInt16BE(0x2131, 0);
  header.writeUInt16BE(32 + body.length, 2);
  header.writeUInt32BE(0, 4);
  header.writeUInt32BE(deviceId >>> 0, 8);
  header.writeUInt32BE(stamp >>> 0, 12);
  const checksum = md5(header.subarray(0, 16), token, body);
  checksum.copy(header, 16);
  return Buffer.concat([header, body]);
}

/** Decrypts a reply and parses its JSON. Returns null when the checksum doesn't match this token. */
export function parsePacket(token, buf) {
  const header = parseHeader(buf);
  if (!header || buf.length <= 32 || header.length !== buf.length) return null;
  const body = buf.subarray(32);
  const expected = md5(buf.subarray(0, 16), token, body);
  if (!expected.equals(header.checksum)) return null;
  const text = decrypt(token, body).toString("utf8").replace(/\0+$/, "");
  return JSON.parse(text);
}

export function isValidToken(value) {
  return typeof value === "string" && /^[0-9a-f]{32}$/i.test(value.trim());
}

/**
 * Sends hello to an address (a device or a broadcast address) and collects replies for `waitMs`.
 * Resolves to [{ ip, deviceId, stamp, token|null }].
 */
export function discover({ address = "255.255.255.255", waitMs = 2500 } = {}) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket("udp4");
    const found = new Map();
    const finish = () => {
      try { socket.close(); } catch {}
      resolve([...found.values()]);
    };
    socket.on("error", finish);
    socket.on("message", (msg, rinfo) => {
      const header = parseHeader(msg);
      if (!header || msg.length !== 32) return;
      found.set(rinfo.address, {
        ip: rinfo.address,
        deviceId: header.deviceId,
        stamp: header.stamp,
        token: tokenFromHello(msg),
      });
    });
    socket.bind(() => {
      try { socket.setBroadcast(true); } catch {}
      const send = () => socket.send(HELLO, MIIO_PORT, address, () => {});
      send();
      setTimeout(send, 300); // UDP: one more try
      setTimeout(finish, waitMs);
    });
  });
}

/** One device: handshake on demand, numbered requests, replies matched by id. */
export class MiioDevice {
  constructor(ip, token) {
    this.ip = ip;
    this.token = Buffer.from(token, "hex");
    this.socket = null;
    this.deviceId = null;
    this.stampBase = 0;
    this.stampAt = 0;
    this.nextId = Math.floor(Math.random() * 1000) + 1;
    this.pending = new Map();
    this.handshakeWaiter = null;
  }

  #open() {
    if (this.socket) return;
    const socket = dgram.createSocket("udp4");
    socket.on("message", (msg) => this.#onMessage(msg));
    socket.on("error", () => this.close());
    socket.bind();
    this.socket = socket;
  }

  #onMessage(msg) {
    const header = parseHeader(msg);
    if (!header) return;
    if (msg.length === 32) {
      this.deviceId = header.deviceId;
      this.stampBase = header.stamp;
      this.stampAt = Date.now();
      this.handshakeWaiter?.();
      return;
    }
    let reply;
    try { reply = parsePacket(this.token, msg); } catch { return; }
    if (!reply || typeof reply.id !== "number") return;
    const waiter = this.pending.get(reply.id);
    if (!waiter) return;
    this.pending.delete(reply.id);
    clearTimeout(waiter.timer);
    if (reply.error) waiter.reject(new Error(reply.error.message ?? JSON.stringify(reply.error)));
    else waiter.resolve(reply.result);
  }

  async #handshake() {
    this.#open();
    for (let attempt = 0; attempt < 3; attempt++) {
      const ok = await new Promise((resolve) => {
        const timer = setTimeout(() => { this.handshakeWaiter = null; resolve(false); }, 1500);
        this.handshakeWaiter = () => { clearTimeout(timer); this.handshakeWaiter = null; resolve(true); };
        this.socket.send(HELLO, MIIO_PORT, this.ip);
      });
      if (ok) return;
    }
    throw new Error("No answer from the device");
  }

  async send(method, params = [], { timeoutMs = 4000 } = {}) {
    // Re-handshake after a minute so the stamp stays in step with the device.
    if (this.deviceId === null || Date.now() - this.stampAt > 60_000) await this.#handshake();
    const id = this.nextId++;
    if (this.nextId > 9999) this.nextId = 1;
    const stamp = this.stampBase + Math.floor((Date.now() - this.stampAt) / 1000);
    const packet = buildPacket(this.token, this.deviceId, stamp, JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.deviceId = null; // handshake again next time
        reject(new Error(`Timeout waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(packet, MIIO_PORT, this.ip);
    });
  }

  close() {
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("Closed"));
    }
    this.pending.clear();
    try { this.socket?.close(); } catch {}
    this.socket = null;
    this.deviceId = null;
  }
}
