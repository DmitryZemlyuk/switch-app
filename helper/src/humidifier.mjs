// Smartmi Evaporative Humidifier 2 (zhimi.humidifier.ca4) over local MIoT.

import { MiioDevice, discover, isValidToken } from "./miio.mjs";

/** MIoT property ids of zhimi.humidifier.ca4. */
export const CA4 = {
  power: { siid: 2, piid: 1 },
  fault: { siid: 2, piid: 2 },
  mode: { siid: 2, piid: 5 }, // 0 auto, 1–3 fan level
  target: { siid: 2, piid: 6 }, // target humidity, 30–80 with the custom MCU firmware
  water: { siid: 2, piid: 7 }, // raw 0–120, 125 full, 127 top removed
  dry: { siid: 2, piid: 8 },
  temperature: { siid: 3, piid: 7 },
  humidity: { siid: 3, piid: 9 },
};

const READ = ["power", "fault", "mode", "target", "water", "temperature", "humidity"];
const LOW_WATER_PERCENT = 20;

/** Raw MIoT water level → { percent, state }. state is "ok", "low" or "open" (top of the humidifier removed). */
export function waterFrom(raw) {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return { percent: null, state: "ok" };
  if (raw >= 127) return { percent: null, state: "open" };
  const percent = raw >= 125 ? 100 : Math.max(0, Math.min(100, Math.round(raw / 1.2)));
  return { percent, state: percent <= LOW_WATER_PERCENT ? "low" : "ok" };
}

/** get_properties result (list of { did, code, value }) → the state object the app gets. */
export function stateFrom(results) {
  const values = {};
  for (const item of results ?? []) {
    if (item && item.code === 0) values[item.did] = item.value;
  }
  const water = waterFrom(values.water);
  return {
    power: values.power === true,
    mode: Number.isInteger(values.mode) ? values.mode : null,
    target: Number.isFinite(values.target) ? values.target : null,
    humidity: Number.isFinite(values.humidity) ? values.humidity : null,
    temperature: Number.isFinite(values.temperature) ? Math.round(values.temperature * 10) / 10 : null,
    waterPercent: water.percent,
    water: water.state,
    fault: Number.isInteger(values.fault) ? values.fault : 0,
  };
}

/** Validates a change from the app. Returns the MIoT value to send, or undefined when invalid. */
export function valueFor(prop, value) {
  switch (prop) {
    case "power":
      return typeof value === "boolean" ? value : undefined;
    case "mode":
      return Number.isInteger(value) && value >= 0 && value <= 3 ? value : undefined;
    case "target":
      return Number.isInteger(value) && value >= 30 && value <= 80 ? value : undefined;
    default:
      return undefined;
  }
}

export class HumidifierController {
  constructor(send, { pollMs = 10_000 } = {}) {
    this.send = send;
    this.pollMs = pollMs;
    this.device = null;
    this.config = null; // { ip, token, deviceId }
    this.timer = null;
    this.failures = 0;
    this.online = null;
    this.polling = false;
  }

  /** Lists Xiaomi devices that answer on the LAN, with their model when the token is known. */
  async find() {
    const found = await discover();
    const devices = [];
    for (const item of found) {
      let model = null;
      if (item.token) {
        const probe = new MiioDevice(item.ip, item.token);
        try {
          const info = await probe.send("miIO.info", [], { timeoutMs: 2500 });
          model = typeof info?.model === "string" ? info.model : null;
        } catch {}
        probe.close();
      }
      devices.push({ ip: item.ip, deviceId: item.deviceId, model, token: item.token });
    }
    this.send({ ev: "humidifier.found", found: devices });
  }

  connect(config) {
    if (!config || typeof config.ip !== "string" || !isValidToken(config.token)) {
      this.send({ ev: "error", code: "humidifier_bad_config", message: "IP or token missing" });
      return;
    }
    this.disconnect();
    this.config = { ip: config.ip, token: config.token.trim().toLowerCase(), deviceId: config.deviceId ?? null };
    this.device = new MiioDevice(this.config.ip, this.config.token);
    this.failures = 0;
    this.online = null;
    this.#schedule(0);
  }

  disconnect() {
    clearTimeout(this.timer);
    this.timer = null;
    this.device?.close();
    this.device = null;
    this.config = null;
  }

  async set(prop, value) {
    const spec = CA4[prop];
    const sendValue = valueFor(prop, value);
    if (!this.device || !spec || sendValue === undefined) return;
    try {
      await this.device.send("set_properties", [{ did: prop, ...spec, value: sendValue }]);
    } catch (error) {
      this.send({ ev: "error", code: "humidifier_set_failed", message: String(error?.message ?? error) });
    }
    this.#schedule(300); // show the result right away
  }

  #schedule(ms) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.#poll(), ms);
  }

  async #poll() {
    if (!this.device || this.polling) return;
    this.polling = true;
    const device = this.device;
    try {
      const params = READ.map((name) => ({ did: name, ...CA4[name] }));
      const result = await device.send("get_properties", params);
      if (device !== this.device) return;
      this.failures = 0;
      // Set up by hand, the device id is unknown: learn it from the handshake so a new IP can be found later.
      if (this.config && this.config.deviceId === null && Number.isInteger(device.deviceId)) {
        this.config.deviceId = device.deviceId;
        this.send({ ev: "humidifier.device", deviceId: device.deviceId });
      }
      this.#setOnline(true);
      this.send({ ev: "humidifier", humidifier: stateFrom(result) });
    } catch (error) {
      if (device !== this.device) return;
      this.failures++;
      // Look for it again after 3 misses and then every ~5 minutes while it stays silent.
      if (this.failures === 3 || this.failures % 30 === 0) {
        this.#setOnline(false);
        process.stderr.write(`humidifier not answering at ${this.config?.ip}: ${error?.message ?? error}\n`);
        await this.#relocate();
      }
    } finally {
      this.polling = false;
      if (this.device) this.#schedule(this.pollMs);
    }
  }

  #setOnline(online) {
    if (this.online === online) return;
    this.online = online;
    this.send({ ev: "humidifier.online", online });
  }

  /** The IP may have changed (DHCP): look for the same device id on the LAN. */
  async #relocate() {
    if (!this.config?.deviceId) return;
    const found = await discover();
    const match = found.find((d) => d.deviceId === this.config?.deviceId);
    if (!match || match.ip === this.config.ip) return;
    const { token, deviceId } = this.config;
    this.connect({ ip: match.ip, token, deviceId });
    this.send({ ev: "humidifier.moved", ip: match.ip });
  }
}
