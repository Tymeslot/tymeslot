/**
 * CalendarCanvas hook: draws the calendar's time grid.
 *
 * Thin glue. The LiveComponent `TymeslotWeb.Dashboard.Calendar.CalendarSurface`
 * owns the data and the chrome; this hook keeps a cache of the events it has
 * been sent (the visible period plus one period either side) and draws the
 * grid from it with the pure modules in ../calendar/.
 *
 * Data flow:
 *  - on mount and reconnect it pulls a payload with `calendar:ready`, so a
 *    lazily loaded hook never misses data pushed before it existed;
 *  - it says whether it is on a phone with calendar:ready and reports a change with calendar:viewport (see calendar_canvas/viewport.js);
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
 *  - a drag moves or resizes an event the organiser can change and pushes
 *    `calendar:move` on the drop (see calendar_canvas/drag.js);
 *  - on a touch screen a long-press on an event starts the same drag, and a
 *    tapped event shows a handle that resizes its end (see
 *    calendar_canvas/touch_drag.js);
 *  - a click or a drag on an empty slot drops a draft for quick create (see
 *    calendar_canvas/draft.js), whose popover pushes `calendar:create` or
 *    `calendar:more_options` (see calendar_canvas/create.js);
 *  - on a focused event the arrow keys move focus, M moves it from the keyboard,
 *    Delete and Ctrl Z push `calendar:delete` and `calendar:undo` (see
 *    calendar_canvas/keys.js);
 *  - Ctrl + scroll, or a pinch on a touch screen, zooms the hours for the
 *    visit (see calendar_canvas/zoom.js and calendar_canvas/gestures.js);
 *  - a sideways swipe over the time grid or the month steps the period and
 *    pushes `calendar:goto` (see calendar_canvas/gestures.js);
 *  - month and agenda draw from the same cache, D X W M A switch views, and
 *    the agenda asks for more with `calendar:agenda_more` as it scrolls (see
 *    calendar_canvas/views.js);
 *  - T, J and K go to today and step the period (see calendar_canvas/power_keys.js);
 *  - the server pushes `calendar:bookable`, the bookable-times layer drawn
 *    behind the events; B switches it, and a day's label opens the explainer
 *    that pushes `calendar:block` (see calendar_canvas/bookable.js);
 *  - it pushes `calendar:open` (an event was clicked) and `calendar:goto`
 *    (a day header was clicked) back to the component.
 *
 * Attach to `#calendar-canvas` (phx-update="ignore"). Required attributes:
 *   data-view, data-date  the period the page was rendered for
 *   data-strings          JSON of translated copy (see ClientStrings)
 */
import { applyPayload, emptyCache, eventsForDays, isLoaded } from "../calendar/cache.js";
import { BookableMixin } from "./calendar_canvas/bookable.js";
import { CommandMixin } from "./calendar_canvas/command.js";
import { CreateMixin } from "./calendar_canvas/create.js";
import { DragMixin } from "./calendar_canvas/drag.js";
import { DraftMixin } from "./calendar_canvas/draft.js";
import { GesturesMixin } from "./calendar_canvas/gestures.js";
import { KeysMixin } from "./calendar_canvas/keys.js";
import { ListMixin } from "./calendar_canvas/list.js";
import { OpeningMixin } from "./calendar_canvas/opening.js";
import { RevealMixin } from "./calendar_canvas/reveal.js";
import { PowerKeysMixin } from "./calendar_canvas/power_keys.js";
import { TouchDragMixin } from "./calendar_canvas/touch_drag.js";
import { ViewportMixin } from "./calendar_canvas/viewport.js";
import { ViewsMixin } from "./calendar_canvas/views.js";
import { ZoomMixin } from "./calendar_canvas/zoom.js";
import { placePopover } from "../calendar/popover.js";
import { tabId } from "../calendar/tab_id.js";
import { HOUR_HEIGHT, MINUTES_PER_DAY, NIGHT_END, dayNumber, isTimeGrid, isoFromDay, makeScale, parseWall, periodDays, shiftPeriod } from "../calendar/time.js";

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
const FOCUS_ATTRS = ["data-event-id", "data-more", "data-allday-more", "data-goto-day", "data-night-toggle", "data-bookable-label", "data-bookable-show", "data-month-day", "data-month-more", "data-agenda-later", "data-agenda-lens"];

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
  ...DragMixin,
  ...DraftMixin,
  ...CreateMixin,
  ...OpeningMixin,
  ...KeysMixin,
  ...ZoomMixin,
  ...BookableMixin,
  ...ViewportMixin,
  ...ViewsMixin,
  ...TouchDragMixin,
  ...GesturesMixin,
  ...ListMixin,
  ...PowerKeysMixin,
  ...CommandMixin,
  ...RevealMixin,

  mounted() {
    this.strings = JSON.parse(this.el.dataset.strings || "{}");
    this.cache = emptyCache();
    this.view = this.el.dataset.view;
    this.date = this.el.dataset.date;
    this.settings = null;
    this.clock = null;
    this.nightOpen = false;
    this.scrollTop = null;
    this.pending = null;
    this.graceTimer = null;
    this.lastWidth = null;
    this.measureWidth = this.measureWidth || canvasMeasure();
    this.tabId = tabId();

    this.mountList();
    this.listeners = [
      ["calendar:navigate", (e) => this.navigate(e.detail)],
      ["click", (e) => this.handleClick(e)],
      ["keydown", (e) => this.handleKey(e)],
    ];
    for (const [name, listener] of this.listeners) this.el.addEventListener(name, listener);
    this.mountDrag();
    this.mountDraft();
    this.mountCreate();
    this.mountKeys();
    this.mountZoom();
    this.mountBookable();
    this.mountViewport();
    this.mountViews();
    this.mountTouchDrag();
    this.mountGestures();
    this.mountPowerKeys();
    this.mountCommand();
    this.mountReveal();

    this.handleEvent("calendar:events", (payload) => this.receive(payload));
    this.handleEvent("calendar:period", (period) => this.follow(period));
    this.handleEvent("calendar:settings", (settings) => {
      // A density chosen in display options replaces any zoom; other changes keep it.
      if (settings.density !== this.settings?.density) this.zoomHour = null;
      this.settings = settings;
      this.render();
    });
    this.handleEvent("calendar:preview-closed", () => this.previewClosed());
    this.handleEvent("calendar:preview-opened", ({ id }) => this.previewOpened(id));
    this.handleEvent("calendar:panel", (change) => this.panelChanged(change));

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
    this.abandonPush();
    this.clearPending();
    this.requestData();
  },

  destroyed() {
    clearInterval(this.timer);
    clearTimeout(this.graceTimer);
    this.resizer?.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.destroyList();
    this.destroyDrag();
    this.destroyDraft();
    this.destroyCreate();
    this.destroyKeys();
    this.destroyZoom();
    this.destroyBookable();
    this.destroyViewport();
    this.destroyViews();
    this.destroyTouchDrag();
    this.destroyGestures();
    this.destroyPowerKeys();
    this.destroyCommand();
    this.destroyReveal();
    const style = document.documentElement.style;
    for (const name of ["--cal-pop-x", "--cal-pop-y", "--cal-pop-h"]) style.removeProperty(name);
    for (const [name, listener] of this.listeners) this.el.removeEventListener(name, listener);
  },

  // The tab id goes with every ready, since a reconnect is a new server
  // process that has to hear it again (it may take back an Undo).
  requestData() {
    this.pushEventTo(this.el, "calendar:ready", { phone: this.phone, tab: this.tabId }, (reply) =>
      this.receive(reply),
    );
  },

  // The cache always takes the payload, but the grid only follows its period
  // when the organiser has not since asked for another one (a late payload for
  // an intermediate period must not snap the grid back). With nothing pending,
  // for instance after browser Back, the server leads.
  receive(payload) {
    this.cache = applyPayload(this.cache, payload);
    this.settleDrafts();
    this.settle(payload);
    if (payload.settings) this.settings = payload.settings;
    // Only the calendar:ready reply carries the bookable layer.
    if (payload.bookable) this.bookable = payload.bookable;
    this.clock = { wall: parseWall(payload.now), at: Date.now() };
    // An open "+N" list is not torn down by a background payload for the period it
    // belongs to; the redraw waits for it to close.
    if (this.overlayOpen() && payload.view === this.view && payload.date === this.date) {
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
    if (view !== this.view || date !== this.date) {
      this.cancelMove({ redraw: false });
      this.selectedId = null;
    }
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
    const view = this.viewFor(detail.view);
    const from = this.pending ?? { view: this.view, date: this.date };
    let { date } = detail;

    // The control's own patch named the period it saw rendered; a step taken
    // while another is pending lands one period further on, so the server is
    // told where the grid really went.
    if (detail.step && from.view === view) {
      date = shiftPeriod(view, from.date, detail.step);
      if (date !== detail.date) this.pushEventTo(this.el, "calendar:goto", { view, date });
    }

    // A scroll asked for by the note's Show applies to its own date only.
    if (this.scrollTarget != null && date !== this.scrollDate) this.scrollTarget = null;

    // The same days again (Today while today shows, the active view, another
    // day of the visible week) need no redraw and no pending answer.
    if (!this.pending && this.sameDays(view, date)) {
      this.date = date;
      return;
    }

    this.cancelMove({ redraw: false });
    this.selectedId = null;
    this.view = view;
    this.date = date;
    this.clearPending();
    this.pending = { view, date };
    this.render();
  },

  sameDays(view, date) {
    if (!this.settings || view !== this.view) return false;
    // A month or an agenda redraws for any other date (the date is a phone's chosen day, or where the list starts).
    if (!isTimeGrid(view)) return date === this.date;
    const { week_start: start, show_weekends: weekends } = this.settings;
    return periodDays(view, date, start, weekends).join() === periodDays(this.view, this.date, start, weekends).join();
  },

  // The minute tick moves the now line; an open "+N" list must not be torn down for it.
  tick() {
    if (this.overlayOpen()) {
      this.dirty = true;
      return;
    }
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
    // A drag owns the dragged block until the drop; redraw then.
    if (this.drag || this.createDrag) return;
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    const previous = this.el.querySelector("[data-scroll]");
    // The note's Show asked for a scroll of its own (see initialScroll).
    if (previous && this.scrollTarget == null) this.scrollTop = previous.scrollTop;

    if (!isLoaded(this.cache, days)) {
      this.dropList();
      this.dropExplainer();
      this.el.innerHTML = this.viewSkeleton(days);
      this.el.setAttribute("aria-busy", "true");
      this.placeQuickCreate();
      return;
    }

    const focused = this.focusKey();
    const now = this.nowMinute();

    this.dropList();
    this.dropExplainer();
    this.lastWidth = this.el.clientWidth;
    this.el.innerHTML = this.drawView({
      view: this.view,
      days,
      events: this.withDraft(this.withMoving(eventsForDays(this.cache, days))),
      movingId: this.moving?.id ?? null,
      settings: this.settings,
      strings: this.strings,
      now,
      width: this.el.clientWidth,
      measureWidth: this.measureWidth,
      nightOpen: this.nightOpen,
      hourHeight: this.hourHeight(),
      bookable: this.bookable,
    });
    this.el.setAttribute("aria-busy", "false");
    this.applyRoving();
    this.afterView();

    const scroller = this.el.querySelector("[data-scroll]");
    if (scroller) scroller.scrollTop = this.scrollTop ?? this.initialScroll(days, now);
    // A deleted event's focus goes to the neighbour chosen when Delete was pressed.
    if (!this.focusBy(focused) && focused && this.pendingFocus) {
      this.focusBy(this.pendingFocus);
      this.pendingFocus = null;
    }
    // The draft may have moved under the quick-create popover.
    this.placeQuickCreate();
    // The selected event's ring and handle (touch_drag.js) go on the fresh blocks.
    this.decorate();
  },

  // First draw: an hour and a half before now when today is in view, else
  // 08:00; after the bookable note's Show, an hour before the time it named.
  initialScroll(days, now) {
    const scale = this.currentScale();
    if (this.scrollTarget != null) {
      const target = Math.max(scale.firstMinute, this.scrollTarget - 60);
      this.scrollTarget = null;
      return Math.max(0, scale.yOf(target) - 4);
    }
    const today = isoFromDay(Math.floor(now / MINUTES_PER_DAY));
    const target = days.includes(today) ? Math.max(NIGHT_END, (now % MINUTES_PER_DAY) - 90) : 480;
    return Math.max(0, scale.yOf(target) - 4);
  },

  // The hour height the grid is drawn at: a Ctrl + scroll zoom (kept
  // fractional in zoomHour, rounded here), else the density's.
  hourHeight() {
    return Math.round(this.zoomHour ?? (HOUR_HEIGHT[this.settings.density] || HOUR_HEIGHT.comfortable));
  },

  currentScale() {
    return makeScale(this.hourHeight(), this.settings.fold_night && !this.nightOpen);
  },

  handleClick(e) {
    // The click that ends a drag is not a click on what lies under it.
    if (this.swallowClick) {
      this.swallowClick = false;
      e.stopPropagation();
      return undefined;
    }
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
      const events = [...this.cache.events.values()].filter((ev) => ev.long && ev.kind !== "draft" && ev.startDay <= day && ev.endDay > day);
      return this.showList(events, allDayMore, this.strings.all_day);
    }

    const header = target.closest("[data-goto-day]");
    if (header) {
      const date = header.dataset.gotoDay;
      this.navigate({ view: "day", date });
      return this.pushEventTo(this.el, "calendar:goto", { view: "day", date });
    }

    const bookableLabel = target.closest("[data-bookable-label]");
    if (bookableLabel) return this.openExplainer(bookableLabel);
    if (target.closest("[data-bookable-copy]")) return this.copyFreeTimes();
    const blockButton = target.closest("[data-bookable-block]");
    if (blockButton) return this.blockTime(blockButton);
    if (this.explainer?.contains(target)) return undefined;

    const show = target.closest("[data-bookable-show]");
    if (show) return this.showBookable(show.dataset.bookableShow);

    if (target.closest("[data-night-toggle]")) {
      this.nightOpen = !this.nightOpen;
      this.scrollTop = null;
      return this.render();
    }

    if (this.viewClick(e)) return undefined;
    // With an event selected on a touch screen, a tap on the empty grid only lets go of it.
    if (this.blockFor(this.selectedId) && this.emptyColumn(target)) {
      this.closeList();
      return this.clearSelection();
    }
    if (this.slotClick(e)) return undefined;
    return this.closeList();
  },

  handleKey(e) {
    // A live drag owns the keyboard; its Escape is the drag mixin's own listener.
    if (this.drag) return undefined;
    if (this.moving) {
      // The move mode belongs to its own block; a key anywhere else ends it first.
      if (e.target.closest?.(".cal-col .cal-ev[data-event-id]")?.dataset.eventId === this.moving.id) return this.movingKey(e);
      this.cancelMove({ announce: false });
    }
    if (e.key === "Escape") {
      if (!e.repeat) {
        this.closeExplainer();
        this.closeList();
        this.clearSelection();
      }
      return undefined;
    }
    const target = e.target.closest?.(".cal-col .cal-ev[data-event-id]");
    if (target && this.el.contains(target) && this.eventKey(e, target)) return undefined;
    if (e.repeat) return undefined;
    if ((e.key === "Enter" || e.key === " ") && e.target.matches?.('[data-event-id][role="button"]')) {
      e.preventDefault();
      this.open(e.target.dataset.eventId, e.target);
    }
    return undefined;
  },

  open(id, anchor) {
    this.select(id);
    this.cancelMove({ announce: false });
    this.lastOpened = id;
    // Opened from a "+N" list, focus returns to its chip: the event itself may
    // be one the chip hides.
    this.returnTo = this.list?.contains(anchor) ? this.listAnchor : null;
    const rect = anchor.getBoundingClientRect();
    this.setPreviewPosition(placePopover(rect, PREVIEW_ESTIMATE, viewport()));
    this.closeList();
    this.closeExplainer();
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
  // travels as CSS variables on <html>, which LiveView never patches. On a
  // phone it is a bottom sheet drawn by CSS (calendar-phone.css), and the
  // variables go.
  setPreviewPosition({ left, top, maxHeight }) {
    const style = document.documentElement.style;
    if (this.sheetMode()) {
      for (const name of ["--cal-pop-x", "--cal-pop-y", "--cal-pop-h"]) style.removeProperty(name);
      return;
    }
    if (maxHeight) style.setProperty("--cal-pop-h", `${Math.round(maxHeight)}px`);
    else style.removeProperty("--cal-pop-h");
    style.setProperty("--cal-pop-x", `${Math.round(left)}px`);
    style.setProperty("--cal-pop-y", `${Math.round(top)}px`);
  },

  // The server opened the preview itself (after the side panel's question
  // about its draft was answered): placed beside the event as a click would
  // place it, and focused.
  previewOpened(id) {
    const anchor = [...this.el.querySelectorAll("[data-event-id]")].find((node) => node.dataset.eventId === id);
    this.select(id);
    this.lastOpened = id;
    this.returnTo = null;
    const rect = anchor ? anchor.getBoundingClientRect() : { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    this.positionPreview(rect);
  },

  previewClosed() {
    const returnTo = this.returnTo;
    this.returnTo = null;
    if (!this.focusBy(returnTo) && this.lastOpened) this.focusBy({ attr: "data-event-id", value: this.lastOpened });
  },

  // The side panel opened or closed beside the grid: the grid's width
  // changed, and focus moves into the panel or back to the event it was for.
  panelChanged({ open, focus }) {
    this.resized();
    if (open) document.querySelector("#calendar-panel [data-panel-focus]")?.focus();
    else if (focus) this.focusBy({ attr: "data-event-id", value: focus });
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
};
