/**
 * CalendarCanvas hook: draws the redesigned calendar's time grid.
 *
 * Thin glue. The LiveComponent `TymeslotWeb.Dashboard.Calendar.CalendarSurface`
 * owns the data and the chrome; this hook keeps a cache of the events it has
 * been sent (the visible period plus one period either side) and draws the
 * grid from it with the pure modules in ../calendar/.
 *
 * Data flow:
 *  - on mount and reconnect it pulls a payload with `calendar:ready`, so a
 *    lazily loaded hook never misses data pushed before it existed;
 *  - the server pushes `calendar:events` whenever what the grid shows changes,
 *    and `calendar:settings` when density or the night fold changes;
 *  - navigation controls patch the URL and dispatch `calendar:navigate` on
 *    this element in the same click; the hook draws the target period at once
 *    when its days are cached, otherwise shows the skeleton until the
 *    server's payload arrives. The target stays pending until the server
 *    confirms it, with `calendar:events` or, when no reload was needed,
 *    `calendar:period`; a step (previous, next) taken while one is pending
 *    steps from it and tells the server with `calendar:goto`. Answers for
 *    another period only overrule it after a short grace, and a reconnect
 *    drops it, since the server reads the URL again;
 *  - it pushes `calendar:open` (an event was clicked) and `calendar:goto`
 *    (a day header was clicked) back to the component.
 *
 * Attach to `#calendar-canvas` (phx-update="ignore"). Required attributes:
 *   data-view, data-date  the period the page was rendered for
 *   data-strings          JSON of translated copy (see ClientStrings)
 */
import { applyPayload, emptyCache, eventsForDays, isLoaded } from "../calendar/cache.js";
import { placePopover } from "../calendar/popover.js";
import { renderGrid, renderList, renderSkeleton } from "../calendar/render.js";
import { HOUR_HEIGHT, MINUTES_PER_DAY, NIGHT_END, dayNumber, isoFromDay, makeScale, parseWall, periodDays, shiftPeriod } from "../calendar/time.js";

const TICK_MS = 60_000;
// How long an answer for another period may disagree with a pending
// navigation before the grid takes it. Long enough for the answer to an
// intermediate step to be overtaken by the one asked for, short enough that a
// period the server corrected (a date out of range falling back) or a request
// it never answered does not leave the grid on a target nobody is loading.
export const PENDING_GRACE_MS = 1_500;
const PREVIEW_ESTIMATE = { width: 320, height: 240 };
// What a redraw can hand focus back to, most specific first. `day` tells the
// per-column night buttons apart, which share an empty attribute value.
const FOCUS_ATTRS = ["data-event-id", "data-more", "data-allday-more", "data-goto-day", "data-night-toggle"];

function canvasMeasure() {
  let context = null;
  try {
    context = document.createElement("canvas").getContext("2d");
  } catch (_error) {
    context = null;
  }
  if (context) context.font = `600 12px ${getComputedStyle(document.body).fontFamily}`;
  const widths = new Map();

  return (text) => {
    if (!context) return text.length * 6.5;
    if (!widths.has(text)) widths.set(text, context.measureText(text).width);
    return widths.get(text);
  };
}

const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });

export const CalendarCanvas = {
  mounted() {
    this.strings = JSON.parse(this.el.dataset.strings || "{}");
    this.cache = emptyCache();
    this.view = this.el.dataset.view;
    this.date = this.el.dataset.date;
    this.settings = null;
    this.clock = null;
    this.nightOpen = false;
    this.scrollTop = null;
    this.list = null;
    this.listAnchor = null;
    this.pending = null;
    this.graceTimer = null;
    this.lastWidth = null;
    this.measureWidth = this.measureWidth || canvasMeasure();

    this.outside = (e) => {
      if (this.list && !this.list.contains(e.target)) this.closeList();
    };
    this.listeners = [
      ["calendar:navigate", (e) => this.navigate(e.detail)],
      ["click", (e) => this.handleClick(e)],
      ["keydown", (e) => this.handleKey(e)],
    ];
    for (const [name, listener] of this.listeners) this.el.addEventListener(name, listener);

    this.handleEvent("calendar:events", (payload) => this.receive(payload));
    this.handleEvent("calendar:period", (period) => this.follow(period));
    this.handleEvent("calendar:settings", (settings) => {
      this.settings = settings;
      this.render();
    });
    this.handleEvent("calendar:preview-closed", () => this.previewClosed());

    if (typeof ResizeObserver !== "undefined") {
      this.resizer = new ResizeObserver(() => this.resized());
      this.resizer.observe(this.el);
    }
    this.timer = setInterval(() => this.tick(), TICK_MS);
    this.requestData();
  },

  // The URL is the source of truth after a reconnect: the server reads it
  // again, so a target still pending from before the drop would wait for an
  // answer that may never come.
  reconnected() {
    this.clearPending();
    this.requestData();
  },

  destroyed() {
    clearInterval(this.timer);
    clearTimeout(this.graceTimer);
    this.resizer?.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.closeList();
    const style = document.documentElement.style;
    for (const name of ["--cal-pop-x", "--cal-pop-y", "--cal-pop-h"]) style.removeProperty(name);
    for (const [name, listener] of this.listeners) this.el.removeEventListener(name, listener);
  },

  requestData() {
    this.pushEventTo(this.el, "calendar:ready", {}, (reply) => this.receive(reply));
  },

  // The cache always takes the payload, but the grid only follows its period
  // when the organiser has not since asked for another one (a late payload for
  // an intermediate period must not snap the grid back). With nothing pending,
  // for instance after browser Back, the server leads.
  receive(payload) {
    this.cache = applyPayload(this.cache, payload);
    this.settle(payload);
    if (payload.settings) this.settings = payload.settings;
    this.clock = { wall: parseWall(payload.now), at: Date.now() };
    // An open "+N" list is not torn down by a background payload for the period it
    // belongs to; the redraw waits for it to close.
    if (this.list && payload.view === this.view && payload.date === this.date) {
      this.dirty = true;
      return;
    }
    this.render();
  },

  // Takes the server's period unless the organiser has asked for another one
  // that it has not confirmed yet. True when the grid now shows it.
  settle({ view, date }) {
    if (this.pending && !(view === this.pending.view && date === this.pending.date)) {
      this.awaitPending({ view, date });
      return false;
    }
    this.clearPending();
    this.view = view;
    this.date = date;
    return true;
  },

  // An answer for another period arrived while one is pending. If the
  // pending one has not been confirmed once the grace runs out, the server's
  // latest period wins.
  awaitPending(answer) {
    this.serverPeriod = answer;
    if (this.graceTimer) return;
    const pending = this.pending;
    this.graceTimer = setTimeout(() => {
      this.graceTimer = null;
      if (this.pending !== pending) return;
      this.pending = null;
      ({ view: this.view, date: this.date } = this.serverPeriod);
      this.render();
    }, PENDING_GRACE_MS);
  },

  clearPending() {
    clearTimeout(this.graceTimer);
    this.graceTimer = null;
    this.pending = null;
  },

  // The server's answer to a URL change that needed no new events.
  follow(period) {
    const { view, date } = this;
    if (!this.settle(period) || (view === this.view && date === this.date)) return;
    this.render();
  },

  navigate(detail) {
    if (!detail || !detail.view || !detail.date) return;
    const { view } = detail;
    const from = this.pending ?? { view: this.view, date: this.date };
    let { date } = detail;

    // The control's own patch named the period it saw rendered; a step taken
    // while another is pending lands one period further on, so the server is
    // told where the grid really went.
    if (detail.step && from.view === view) {
      date = shiftPeriod(view, from.date, detail.step);
      if (date !== detail.date) this.pushEventTo(this.el, "calendar:goto", { view, date });
    }

    // The same days again (Today while today shows, the active view, another
    // day of the visible week) need no redraw and no pending answer.
    if (!this.pending && this.sameDays(view, date)) {
      this.date = date;
      return;
    }

    this.view = view;
    this.date = date;
    this.clearPending();
    this.pending = { view, date };
    this.render();
  },

  sameDays(view, date) {
    if (!this.settings || view !== this.view) return false;
    const { week_start: start, show_weekends: weekends } = this.settings;
    return periodDays(view, date, start, weekends).join() === periodDays(this.view, this.date, start, weekends).join();
  },

  // The minute tick moves the now line; an open "+N" list must not be torn down for it.
  tick() {
    if (this.list) return;
    this.render();
  },

  resized() {
    if (this.el.clientWidth === this.lastWidth) return;
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.render();
    });
  },

  nowMinute() {
    return this.clock.wall + Math.floor((Date.now() - this.clock.at) / 60_000);
  },

  render() {
    if (!this.settings || !this.clock) return;
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    const previous = this.el.querySelector("[data-scroll]");
    if (previous) this.scrollTop = previous.scrollTop;

    if (!isLoaded(this.cache, days)) {
      this.dropList();
      this.el.innerHTML = renderSkeleton(days, this.strings);
      this.el.setAttribute("aria-busy", "true");
      return;
    }

    const focused = this.focusKey();
    const now = this.nowMinute();

    this.dropList();
    this.lastWidth = this.el.clientWidth;
    this.el.innerHTML = renderGrid({
      view: this.view,
      days,
      events: eventsForDays(this.cache, days),
      settings: this.settings,
      strings: this.strings,
      now,
      width: this.el.clientWidth,
      measureWidth: this.measureWidth,
      nightOpen: this.nightOpen,
    });
    this.el.setAttribute("aria-busy", "false");

    const scroller = this.el.querySelector("[data-scroll]");
    if (scroller) scroller.scrollTop = this.scrollTop ?? this.initialScroll(days, now);
    this.focusBy(focused);
  },

  // First draw: an hour and a half before now when today is in view, else 08:00.
  initialScroll(days, now) {
    const scale = makeScale(HOUR_HEIGHT[this.settings.density] || HOUR_HEIGHT.comfortable, this.settings.fold_night && !this.nightOpen);
    const today = isoFromDay(Math.floor(now / MINUTES_PER_DAY));
    const target = days.includes(today) ? Math.max(NIGHT_END, (now % MINUTES_PER_DAY) - 90) : 480;
    return Math.max(0, scale.yOf(target) - 4);
  },

  handleClick(e) {
    const target = e.target;
    const event = target.closest("[data-event-id]");
    if (event) {
      // Opening one event must not reach LiveView's window-level click-away,
      // or it would close the preview this click is opening.
      e.stopPropagation();
      return this.open(event.dataset.eventId, event);
    }

    const more = target.closest("[data-more]");
    if (more) return this.showList(more.dataset.more.split(",").map((id) => this.cache.events.get(id)).filter(Boolean), more, this.strings.list_label);

    const allDayMore = target.closest("[data-allday-more]");
    if (allDayMore) {
      const day = dayNumber(allDayMore.dataset.alldayMore);
      const events = [...this.cache.events.values()].filter((ev) => ev.long && ev.startDay <= day && ev.endDay > day);
      return this.showList(events, allDayMore, this.strings.all_day);
    }

    const header = target.closest("[data-goto-day]");
    if (header) {
      const date = header.dataset.gotoDay;
      this.navigate({ view: "day", date });
      return this.pushEventTo(this.el, "calendar:goto", { view: "day", date });
    }

    if (target.closest("[data-night-toggle]")) {
      this.nightOpen = !this.nightOpen;
      this.scrollTop = null;
      return this.render();
    }

    return this.closeList();
  },

  handleKey(e) {
    if (e.repeat) return undefined;
    if (e.key === "Escape") return this.closeList();
    if ((e.key === "Enter" || e.key === " ") && e.target.matches?.('[data-event-id][role="button"]')) {
      e.preventDefault();
      this.open(e.target.dataset.eventId, e.target);
    }
    return undefined;
  },

  open(id, anchor) {
    this.lastOpened = id;
    // Opened from a "+N" list, focus returns to its chip: the event itself may
    // be one the chip hides.
    this.returnTo = this.list?.contains(anchor) ? this.listAnchor : null;
    const rect = anchor.getBoundingClientRect();
    this.setPreviewPosition(placePopover(rect, PREVIEW_ESTIMATE, viewport()));
    this.closeList();
    this.pushEventTo(this.el, "calendar:open", { id }, () => this.positionPreview(rect));
  },

  positionPreview(rect) {
    const preview = document.getElementById("calendar-preview");
    if (!preview) return;
    document.documentElement.style.removeProperty("--cal-pop-h");
    this.setPreviewPosition(placePopover(rect, { width: preview.offsetWidth || PREVIEW_ESTIMATE.width, height: preview.offsetHeight || PREVIEW_ESTIMATE.height }, viewport()));
    preview.focus({ preventScroll: true });
  },

  // The preview is rendered by LiveView outside this element, so its position
  // travels as CSS variables on <html>, which LiveView never patches.
  setPreviewPosition({ left, top, maxHeight }) {
    const style = document.documentElement.style;
    if (maxHeight) style.setProperty("--cal-pop-h", `${Math.round(maxHeight)}px`);
    else style.removeProperty("--cal-pop-h");
    style.setProperty("--cal-pop-x", `${Math.round(left)}px`);
    style.setProperty("--cal-pop-y", `${Math.round(top)}px`);
  },

  previewClosed() {
    const returnTo = this.returnTo;
    this.returnTo = null;
    if (!this.focusBy(returnTo) && this.lastOpened) this.focusBy({ attr: "data-event-id", value: this.lastOpened });
  },

  // A description of the focused control that survives a redraw.
  focusKey() {
    const active = document.activeElement;
    return active && this.el.contains(active) ? this.focusKeyOf(active) : null;
  },

  focusKeyOf(element) {
    for (const attr of FOCUS_ATTRS) {
      const node = element.closest(`[${attr}]`);
      if (node && this.el.contains(node)) return { attr, value: node.getAttribute(attr), day: node.closest("[data-day]")?.dataset.day };
    }
    return null;
  },

  // Focuses the control `key` describes; true when one was found.
  focusBy(key) {
    if (!key) return false;
    const target = [...this.el.querySelectorAll(`[${key.attr}]`)].find(
      (node) => node.getAttribute(key.attr) === key.value && (key.day === undefined || node.closest("[data-day]")?.dataset.day === key.day),
    );
    target?.focus({ preventScroll: true });
    return !!target;
  },

  showList(events, anchor, label) {
    this.closeList();
    const holder = document.createElement("div");
    holder.innerHTML = renderList([...events].sort((a, b) => a.startMin - b.startMin), { strings: this.strings, timeFormat: this.settings.time_format, label });
    const list = holder.firstElementChild;
    this.el.appendChild(list);

    const position = placePopover(anchor.getBoundingClientRect(), { width: list.offsetWidth || 240, height: list.offsetHeight || 160 }, viewport());
    list.style.left = `${Math.round(position.left)}px`;
    list.style.top = `${Math.round(position.top)}px`;
    list.style.maxHeight = position.maxHeight ? `${Math.round(position.maxHeight)}px` : "";
    this.list = list;
    this.listAnchor = this.focusKeyOf(anchor);
    document.addEventListener("pointerdown", this.outside);
    list.querySelector("button")?.focus();
  },

  // Forget the list without touching focus (the grid redraw has removed it).
  dropList() {
    document.removeEventListener("pointerdown", this.outside);
    this.list = null;
    this.dirty = false;
  },

  closeList() {
    if (!this.list) return;
    const hadFocus = this.list.contains(document.activeElement);
    const stale = this.dirty;
    this.list.remove();
    this.dropList();
    if (stale) this.render();
    if (hadFocus) this.focusBy(this.listAnchor);
  },
};
