/**
 * AgendaCountdown hook
 *
 * Drives the live "in 40m" countdown on the dashboard agenda hero, and reveals
 * the Join button as the appointment approaches — all client-side, so there are
 * no server round-trips just to tick a clock.
 *
 * Attach to the countdown element. Required data attributes:
 *   data-start  — ISO-8601 start time of the appointment
 *   data-end    — ISO-8601 end time of the appointment
 *
 * Optional:
 *   data-join   — id of a Join element to reveal from T-10m until the end
 */
const TICK_MS = 30_000;
const JOIN_LEAD_MS = 10 * 60 * 1000;

function relative(ms) {
  if (ms <= 0) return "now";
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `in ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    const rem = minutes % 60;
    return rem ? `in ${hours}h ${rem}m` : `in ${hours}h`;
  }
  const days = Math.floor(hours / 24);
  return `in ${days}d`;
}

export const AgendaCountdown = {
  mounted() {
    this._render();
    this._timer = setInterval(() => this._render(), TICK_MS);
  },

  updated() {
    this._render();
  },

  destroyed() {
    clearInterval(this._timer);
  },

  _render() {
    const start = new Date(this.el.dataset.start).getTime();
    const end = new Date(this.el.dataset.end).getTime();
    const now = Date.now();
    const toStart = start - now;

    this.el.textContent = relative(toStart);

    const joinId = this.el.dataset.join;
    if (!joinId) return;

    const button = document.getElementById(joinId);
    if (!button) return;

    const withinJoinWindow = toStart <= JOIN_LEAD_MS && now < end;
    button.classList.toggle("hidden", !withinJoinWindow);
    button.classList.toggle("inline-flex", withinJoinWindow);
  },
};
