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
 *  - navigation controls dispatch `calendar:navigate` on this element and
 *    patch the URL in the same click; the hook draws the target period at once
 *    when its days are cached, otherwise shows the skeleton until the
 *    server's payload arrives;
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
import { HOUR_HEIGHT, MINUTES_PER_DAY, NIGHT_END, dayNumber, isoFromDay, makeScale, parseWall, periodDays } from "../calendar/time.js";

const TICK_MS = 60_000;
const PREVIEW_ESTIMATE = { width: 320, height: 240 };

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
    this.handleEvent("calendar:settings", (settings) => {
      this.settings = settings;
      this.render();
    });
    this.handleEvent("calendar:preview-closed", () => this.focusEvent(this.lastOpened));

    if (typeof ResizeObserver !== "undefined") {
      this.resizer = new ResizeObserver(() => this.resized());
      this.resizer.observe(this.el);
    }
    this.timer = setInterval(() => this.tick(), TICK_MS);
    this.requestData();
  },

  reconnected() {
    this.requestData();
  },

  destroyed() {
    clearInterval(this.timer);
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
    if (!this.pending || (payload.view === this.pending.view && payload.date === this.pending.date)) {
      this.view = payload.view;
      this.date = payload.date;
      this.pending = null;
    }
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

  navigate(detail) {
    if (!detail || !detail.view || !detail.date) return;
    this.view = detail.view;
    this.date = detail.date;
    this.pending = { view: detail.view, date: detail.date };
    this.render();
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

    const focused = this.el.contains(document.activeElement) ? document.activeElement.closest("[data-event-id]")?.dataset.eventId : null;
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
    if (focused) this.focusEvent(focused);
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

  focusEvent(id) {
    if (!id) return;
    const target = [...this.el.querySelectorAll("[data-event-id]")].find((node) => node.dataset.eventId === id);
    target?.focus({ preventScroll: true });
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
    this.listAnchor = { name: anchor.hasAttribute("data-more") ? "more" : "alldayMore", value: anchor.dataset.more ?? anchor.dataset.alldayMore };
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
    if (!hadFocus || !this.listAnchor) return;
    const { name, value } = this.listAnchor;
    const chip = [...this.el.querySelectorAll("[data-more], [data-allday-more]")].find((node) => node.dataset[name] === value);
    chip?.focus({ preventScroll: true });
  },
};
