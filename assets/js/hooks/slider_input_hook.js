/**
 * SliderInput hook
 *
 * Provides real-time visual feedback for styled <input type="range"> elements:
 *   - Updates the track fill gradient as the thumb moves
 *   - Forwards the current value to a sibling display element
 *
 * Required data attributes on the input:
 *   data-display  — ID of the element that shows the current value
 *
 * Optional data attributes:
 *   data-prefix   — string prepended to the value in the display (e.g. "€")
 *   data-suffix   — string appended to the value in the display (e.g. "m")
 */
export const SliderInputHook = {
  mounted() {
    this._onInput = () => this._update();
    this.el.addEventListener("input", this._onInput);
    this._update();
  },

  destroyed() {
    this.el.removeEventListener("input", this._onInput);
  },

  _update() {
    const el = this.el;
    const min = parseFloat(el.min) || 0;
    const max = parseFloat(el.max) || 100;
    const val = parseFloat(el.value) || min;
    const pct = ((val - min) / (max - min)) * 100;

    el.style.background =
      `linear-gradient(to right, var(--color-primary-500) ${pct}%, var(--color-neutral-700) ${pct}%)`;

    const display = document.getElementById(el.dataset.display);
    if (display) {
      const prefix = el.dataset.prefix || "";
      const suffix = el.dataset.suffix || "";
      display.textContent = prefix + val + suffix;
    }
  }
};
