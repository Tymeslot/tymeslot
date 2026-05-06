/**
 * CustomColourPicker hook
 *
 * On-brand HSV colour picker. Owns its DOM after mount: drag interactions,
 * hue rail, and hex input all run client-side without LiveView round-trips.
 * Only commits to the server on pointer-up, hue release, or hex blur/Enter —
 * at which point it pushes the event named in `data-event` to the
 * LiveComponent CID stored in `data-target`, with a `{value: <hex>}` payload.
 *
 * Required data attributes on the root element:
 *   data-target       — phx CID of the LiveComponent that handles the event
 *   data-event        — event name to push on commit (e.g. "theme:set_palette_seed")
 *   data-initial-hex  — the colour to seed the picker from (e.g. "#06b6d4")
 *
 * Required descendants (matched by data-cp attribute):
 *   [data-cp="canvas"]        — <canvas> for saturation/value
 *   [data-cp="canvas-thumb"]  — absolutely positioned thumb inside the canvas wrapper
 *   [data-cp="hue"]           — <input type="range" min="0" max="360">
 *   [data-cp="hex"]           — <input type="text">
 *   [data-cp="preview"]       — element whose background-color reflects the current colour
 */
export const CustomColourPicker = {
  mounted() {
    this._cacheNodes();
    this._hsv = { h: 0, s: 1, v: 1 };

    const initial = this.el.dataset.initialHex || "#06b6d4";
    this._setStateFromHex(initial);
    this._renderCanvas();
    this._positionCanvasThumb();
    this._paintHueRail();
    this._bindEvents();
  },

  updated() {
    // Re-sync when the server-persisted value changed *outside* of this picker
    // (e.g. user clicked a preset swatch while the panel was open).
    const incoming = (this.el.dataset.initialHex || "").toLowerCase();
    const current = this._currentHex().toLowerCase();
    if (incoming && incoming !== current) {
      this._setStateFromHex(incoming);
      this._syncUI();
    }
  },

  destroyed() {
    this._unbindEvents();
  },

  // --- DOM caching ---------------------------------------------------------

  _cacheNodes() {
    const q = (sel) => this.el.querySelector(sel);
    this.canvas = q('[data-cp="canvas"]');
    this.canvasThumb = q('[data-cp="canvas-thumb"]');
    this.hueInput = q('[data-cp="hue"]');
    this.hexInput = q('[data-cp="hex"]');
    this.preview = q('[data-cp="preview"]');
    this.ctx = this.canvas.getContext("2d");
    this.target = this.el.dataset.target;
    this.event = this.el.dataset.event || "theme:set_palette_seed";
  },

  _bindEvents() {
    this._handlers = {
      canvasDown: (e) => this._onCanvasDown(e),
      hueInput: () => this._onHueInput(),
      hueChange: () => this._commit(),
      hexBlur: () => this._onHexCommit(),
      hexKey: (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          this.hexInput.blur();
        }
      },
      resize: () => this._renderCanvas(),
    };

    this.canvas.addEventListener("pointerdown", this._handlers.canvasDown);
    this.hueInput.addEventListener("input", this._handlers.hueInput);
    this.hueInput.addEventListener("change", this._handlers.hueChange);
    this.hexInput.addEventListener("blur", this._handlers.hexBlur);
    this.hexInput.addEventListener("keydown", this._handlers.hexKey);
    window.addEventListener("resize", this._handlers.resize);
  },

  _unbindEvents() {
    if (!this._handlers) return;
    this.canvas.removeEventListener("pointerdown", this._handlers.canvasDown);
    this.hueInput.removeEventListener("input", this._handlers.hueInput);
    this.hueInput.removeEventListener("change", this._handlers.hueChange);
    this.hexInput.removeEventListener("blur", this._handlers.hexBlur);
    this.hexInput.removeEventListener("keydown", this._handlers.hexKey);
    window.removeEventListener("resize", this._handlers.resize);
  },

  // --- Interactions --------------------------------------------------------

  _onCanvasDown(e) {
    e.preventDefault();
    this.canvas.setPointerCapture(e.pointerId);
    this._updateFromCanvasEvent(e);

    const move = (ev) => this._updateFromCanvasEvent(ev);
    const up = () => {
      this.canvas.releasePointerCapture(e.pointerId);
      this.canvas.removeEventListener("pointermove", move);
      this.canvas.removeEventListener("pointerup", up);
      this.canvas.removeEventListener("pointercancel", up);
      this._commit();
    };
    this.canvas.addEventListener("pointermove", move);
    this.canvas.addEventListener("pointerup", up);
    this.canvas.addEventListener("pointercancel", up);
  },

  _updateFromCanvasEvent(e) {
    const rect = this.canvas.getBoundingClientRect();
    this._hsv.s = clamp((e.clientX - rect.left) / rect.width, 0, 1);
    this._hsv.v = 1 - clamp((e.clientY - rect.top) / rect.height, 0, 1);
    this._syncFromHsv({ skipCanvas: true });
  },

  _onHueInput() {
    this._hsv.h = parseFloat(this.hueInput.value) || 0;
    this._syncFromHsv();
  },

  _onHexCommit() {
    const raw = this.hexInput.value.trim();
    const normalised = raw.startsWith("#") ? raw : "#" + raw;
    if (!/^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/.test(normalised)) {
      // Reject — restore the last valid value.
      this._syncUI();
      return;
    }
    this._setStateFromHex(normalised);
    this._syncUI();
    this._commit();
  },

  _commit() {
    const hex = this._currentHex();
    const payload = { value: hex };
    if (this.target) {
      this.pushEventTo(this.target, this.event, payload);
    } else {
      this.pushEvent(this.event, payload);
    }
  },

  // --- State sync ----------------------------------------------------------

  _setStateFromHex(hex) {
    const rgb = hexToRgb(hex);
    if (!rgb) return;
    this._hsv = rgbToHsv(rgb);
  },

  _syncFromHsv({ skipCanvas } = {}) {
    const hex = this._currentHex();
    this.hexInput.value = hex.toUpperCase();
    this.preview.style.backgroundColor = hex;
    this.hueInput.value = Math.round(this._hsv.h);
    if (!skipCanvas) this._renderCanvas();
    this._positionCanvasThumb();
  },

  _syncUI() {
    this._syncFromHsv();
  },

  _currentHex() {
    return hsvToHex(this._hsv);
  },

  // --- Rendering -----------------------------------------------------------

  _renderCanvas() {
    const w = this.canvas.width;
    const h = this.canvas.height;
    const baseHex = hsvToHex({ h: this._hsv.h, s: 1, v: 1 });

    const sat = this.ctx.createLinearGradient(0, 0, w, 0);
    sat.addColorStop(0, "#ffffff");
    sat.addColorStop(1, baseHex);
    this.ctx.fillStyle = sat;
    this.ctx.fillRect(0, 0, w, h);

    const val = this.ctx.createLinearGradient(0, 0, 0, h);
    val.addColorStop(0, "rgba(0,0,0,0)");
    val.addColorStop(1, "#000000");
    this.ctx.fillStyle = val;
    this.ctx.fillRect(0, 0, w, h);
  },

  _positionCanvasThumb() {
    const x = this._hsv.s * 100;
    const y = (1 - this._hsv.v) * 100;
    this.canvasThumb.style.left = `${x}%`;
    this.canvasThumb.style.top = `${y}%`;
    this.canvasThumb.style.backgroundColor = this._currentHex();
  },

  _paintHueRail() {
    // Static rainbow track painted once via inline style — avoids a CSS dependency.
    const stops = [
      "#ff0000", "#ffff00", "#00ff00", "#00ffff",
      "#0000ff", "#ff00ff", "#ff0000",
    ].join(", ");
    this.hueInput.style.background = `linear-gradient(to right, ${stops})`;
  },

};

// --- Colour math -----------------------------------------------------------

function clamp(n, lo, hi) {
  return Math.min(hi, Math.max(lo, n));
}

function hexToRgb(hex) {
  let h = hex.replace("#", "").trim();
  if (h.length === 3) h = h.split("").map((c) => c + c).join("");
  if (!/^[0-9a-fA-F]{6}$/.test(h)) return null;
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16),
  };
}

function rgbToHsv({ r, g, b }) {
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    switch (max) {
      case rn: h = ((gn - bn) / d) % 6; break;
      case gn: h = (bn - rn) / d + 2; break;
      default: h = (rn - gn) / d + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
  }
  const s = max === 0 ? 0 : d / max;
  const v = max;
  return { h, s, v };
}

function hsvToHex({ h, s, v }) {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let rp, gp, bp;
  if (h < 60)        { [rp, gp, bp] = [c, x, 0]; }
  else if (h < 120)  { [rp, gp, bp] = [x, c, 0]; }
  else if (h < 180)  { [rp, gp, bp] = [0, c, x]; }
  else if (h < 240)  { [rp, gp, bp] = [0, x, c]; }
  else if (h < 300)  { [rp, gp, bp] = [x, 0, c]; }
  else               { [rp, gp, bp] = [c, 0, x]; }
  const toHex = (n) => {
    const v = Math.round((n + m) * 255);
    return clamp(v, 0, 255).toString(16).padStart(2, "0");
  };
  return "#" + toHex(rp) + toHex(gp) + toHex(bp);
}
