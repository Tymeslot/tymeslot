/**
 * AgendaCountdown hook
 *
 * Drives the live "in 40m" countdown on the dashboard agenda hero, and reveals
 * the Join button as the appointment approaches — all client-side, so there are
 * no server round-trips just to tick a clock.
 *
 * The band wording is never composed in JS: the server (see
 * `TymeslotWeb.Dashboard.DashboardOverviewFormatters.countdown_templates/0`)
 * renders each band's translated text with a `__N__` placeholder, and this
 * hook only ever substitutes the live number into whichever template the
 * server sent. That keeps the countdown's wording and band boundaries defined
 * in exactly one place, in the user's locale, instead of duplicated in JS.
 *
 * Attach to the countdown element. Required data attributes:
 *   data-start        — ISO-8601 start time of the appointment
 *   data-end          — ISO-8601 end time of the appointment
 *   data-tpl-now      — translated text for "starting now"
 *   data-tpl-minutes  — translated template, under an hour away
 *   data-tpl-hours    — translated template, under a day away
 *   data-tpl-days     — translated template, a day or more away
 *
 * Optional:
 *   data-join   — id of a Join element to reveal from T-10m until the end
 */
const TICK_MS = 30_000;
const JOIN_LEAD_MS = 10 * 60 * 1000;
const PLACEHOLDER = "__N__";

function relative(ms, templates) {
  if (ms <= 0) return templates.now;
  const seconds = Math.floor(ms / 1000);
  if (seconds < 3600) {
    return templates.minutes.replace(PLACEHOLDER, Math.max(Math.floor(seconds / 60), 1));
  }
  if (seconds < 86_400) {
    return templates.hours.replace(PLACEHOLDER, Math.floor(seconds / 3600));
  }
  return templates.days.replace(PLACEHOLDER, Math.floor(seconds / 86_400));
}

export const AgendaCountdown = {
  mounted() {
    this._templates = {
      now: this.el.dataset.tplNow,
      minutes: this.el.dataset.tplMinutes,
      hours: this.el.dataset.tplHours,
      days: this.el.dataset.tplDays,
    };
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

    this.el.textContent = relative(toStart, this._templates);

    const joinId = this.el.dataset.join;
    if (!joinId) return;

    const button = document.getElementById(joinId);
    if (!button) return;

    const withinJoinWindow = toStart <= JOIN_LEAD_MS && now < end;
    button.classList.toggle("hidden", !withinJoinWindow);
    button.classList.toggle("inline-flex", withinJoinWindow);
  },
};
