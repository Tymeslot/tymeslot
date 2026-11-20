/**
 * The CalendarCanvas hook's month and agenda views (mixed into it).
 *
 * `render()` (calendar_canvas.js) hands its model to `drawView`, which draws
 * the time grid for day, three days and week (render.js), the month grid
 * (render_month.js) or the agenda list (render_agenda.js), all from the
 * same cache; `viewSkeleton` stands in while a view's days load, and
 * `afterView` runs after each draw (and lets a search reveal look for its event).
 *
 * Month: a click on an event opens its preview (the hook's own
 * `[data-event-id]` handling); a click elsewhere in a day opens that day in
 * Day view, or on a phone (`this.phone`, set by the viewport mixin) chooses
 * the day, whose events show under the grid; "+N" lists the day; the arrow
 * keys, Home and End move between days, one of which is the tab stop.
 *
 * Agenda: the days from its date that the cache holds in a row. When its
 * end comes into sight it asks for the next weeks (`calendar:agenda_more`,
 * one request at a time) and merges the answer into the cache; once the
 * server says it is done, "Show later" moves the date on. Its lens (All or
 * Bookings, `this.agendaLens`) filters what it lists, and lasts as long as
 * the hook does.
 *
 * Month and agenda scroll in `[data-view-scroll]`, kept across redraws of
 * the same view and date; the time grid's own position (`[data-scroll]`,
 * `this.scrollTop`) waits for the return to a time view.
 *
 * D, X, W, M and A switch views anywhere on the page but a text field, a
 * dialog or a modal; `switchView` opens the next view at the week or month
 * shown (today when it is in it, else the first day), as the toolbar does. M on a focused event belongs to the event: the
 * keyboard move (keys.js) where it can move, nothing where it cannot.
 */
import { AGENDA_LENSES, agendaDays, agendaGroups, lensEvents } from "../../calendar/agenda.js";
import { applyPayload, eventsForDays, isLoaded } from "../../calendar/cache.js";
import { monthStep } from "../../calendar/month.js";
import { renderAgenda } from "../../calendar/render_agenda.js";
import { renderMonth } from "../../calendar/render_month.js";
import { renderWeekStrip } from "../../calendar/render_strip.js";
import { dateLabel, renderGrid, renderSkeleton } from "../../calendar/render.js";
import { AGENDA_MAX_DAYS, MINUTES_PER_DAY, addDays, isTimeGrid, isoFromDay, periodDays, viewSwitchAnchor } from "../../calendar/time.js";
import { metricsFor } from "../../calendar/viewport.js";
import { MODALS, TYPING } from "./keys.js";

const VIEW_KEYS = { d: "day", x: "three_day", w: "week", m: "month", a: "agenda" };
const MONTH_KEYS = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);
// The month's weekday row, above its six weeks.
const MONTH_HEAD = 28;
const MIN_CELL = 48;
// Quick create outside the time grid looks this many days from the view's date.
const CREATE_DAYS = 7;
// The agenda asks for more this far before its end shows.
const AGENDA_LOOKAHEAD = "0px 0px 400px 0px";
// A load-more whose answer never came (a dropped socket) may be asked again after this.
const AGENDA_RETRY_MS = 10_000;

const withoutDrafts = (events) => events.filter((e) => e.kind !== "draft");

export const ViewsMixin = {
  mountViews() {
    this.agendaLoading = 0;
    this.agendaDone = null;
    this.agendaLens = "all";
    this.agendaObserver = null;
    this.viewScrollTop = 0;
    this.drawnView = null;
    this.monthFocus = null;
    this.viewKeyListener = (e) => this.viewKey(e);
    this.monthKeyListener = (e) => this.monthKey(e);
    document.addEventListener("keydown", this.viewKeyListener);
    this.el.addEventListener("keydown", this.monthKeyListener);
  },

  destroyViews() {
    document.removeEventListener("keydown", this.viewKeyListener);
    this.el.removeEventListener("keydown", this.monthKeyListener);
    this.agendaObserver?.disconnect();
    this.agendaObserver = null;
  },

  // The days the view draws: for the agenda, as far as the cache holds them in a row.
  viewDays() {
    if (this.view === "agenda") return agendaDays(this.cache, this.date);
    return periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
  },

  viewSkeleton(days) {
    if (this.view === "month") return renderSkeleton(days.slice(0, 7), this.strings);
    if (this.view === "agenda") return renderSkeleton(days.slice(0, 1), this.strings);
    return renderSkeleton(days, this.strings);
  },

  // Day view on a phone: the week around the day, with dots, above the grid.
  // Its buttons carry data-goto-day, so a tap takes the grid's own route to
  // that day. Empty until the week is cached (Day view loads the week's window).
  weekStrip(today) {
    if (!this.phone || this.view !== "day") return "";
    const days = periodDays("week", this.date, this.settings.week_start, true);
    if (!isLoaded(this.cache, days)) return "";
    const events = eventsForDays(this.cache, days).filter((event) => event.kind !== "draft");
    return renderWeekStrip({ days, date: this.date, today, events, strings: this.strings });
  },

  drawView(model) {
    this.keepViewScroll();
    const today = isoFromDay(Math.floor(model.now / MINUTES_PER_DAY));
    if (isTimeGrid(this.view)) return this.weekStrip(today) + renderGrid({ ...model, metrics: metricsFor(Boolean(this.phone)) });

    if (this.view === "month") {
      return renderMonth({
        days: model.days,
        date: this.date,
        today,
        events: withoutDrafts(model.events),
        settings: this.settings,
        strings: this.strings,
        phone: Boolean(this.phone),
        cellHeight: Math.max(MIN_CELL, (this.el.clientHeight - MONTH_HEAD) / 6),
        now: model.now,
      });
    }

    const days = this.viewDays();
    return renderAgenda({
      groups: agendaGroups(lensEvents(withoutDrafts(eventsForDays(this.cache, days)), this.agendaLens), days, { today }),
      strings: this.strings,
      timeFormat: this.settings.time_format,
      now: model.now,
      done: this.agendaFinished(days),
      loading: this.agendaBusy(),
      lens: this.agendaLens,
      density: this.settings.density,
    });
  },

  // Remembers the list's scroll before a redraw replaces it: the same view
  // and date keep it, anything else starts at the top.
  keepViewScroll() {
    const list = this.el.querySelector("[data-view-scroll]");
    const same = this.drawnView && this.drawnView.view === this.view && this.drawnView.date === this.date;
    this.viewScrollTop = list && same ? list.scrollTop : 0;
    // The arrows' last day belongs to the month it was in.
    if (!same) this.monthFocus = null;
    this.drawnView = { view: this.view, date: this.date };
  },

  afterView() {
    const list = this.el.querySelector("[data-view-scroll]");
    if (list) list.scrollTop = this.viewScrollTop;
    this.applyMonthFocus();
    this.watchAgendaEnd();
    this.afterReveal();
  },

  // One month day is the tab stop: the one the arrows last reached when it
  // is still drawn, else the one the renderer chose (the view's date).
  applyMonthFocus() {
    const days = [...this.el.querySelectorAll("[data-month-day]")];
    if (!days.length) return;
    const chosen = days.find((b) => b.dataset.monthDay === this.monthFocus) || days.find((b) => b.tabIndex === 0) || days[0];
    for (const b of days) b.tabIndex = b === chosen ? 0 : -1;
  },

  monthKey(e) {
    if (!MONTH_KEYS.has(e.key) || e.altKey || e.ctrlKey || e.metaKey) return;
    const button = e.target.closest?.("[data-month-day]");
    if (!button || !this.el.contains(button)) return;
    const days = [...this.el.querySelectorAll("[data-month-day]")];
    const target = days[monthStep(days.indexOf(button), e.key, days.length)];
    e.preventDefault();
    this.monthFocus = target.dataset.monthDay;
    for (const b of days) b.tabIndex = b === target ? 0 : -1;
    target.focus();
  },

  watchAgendaEnd() {
    this.agendaObserver?.disconnect();
    this.agendaObserver = null;
    const sentinel = this.el.querySelector("[data-agenda-sentinel]");
    if (!sentinel || typeof IntersectionObserver === "undefined") return;
    this.agendaObserver = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) this.loadMoreAgenda();
      },
      { root: this.el.querySelector("[data-view-scroll]"), rootMargin: AGENDA_LOOKAHEAD },
    );
    this.agendaObserver.observe(sentinel);
  },

  loadMoreAgenda() {
    if (this.view !== "agenda" || this.agendaBusy()) return;
    const days = this.viewDays();
    if (!days.length || this.agendaFinished(days)) return;
    const date = this.date;
    // A late reply must not clear the busy flag of a newer request.
    const ticket = (this.agendaTicket = (this.agendaTicket || 0) + 1);
    this.agendaLoading = Date.now();
    this.pushEventTo(this.el, "calendar:agenda_more", { through: days[days.length - 1] }, (reply) => {
      if (this.agendaTicket === ticket) this.agendaLoading = 0;
      // The server may answer against a newer agenda's window when the organiser
      // navigated before the reply: such a payload is ignored.
      const payload = reply?.payload?.view === "agenda" && reply.payload.date === this.date ? reply.payload : null;
      if (payload) this.cache = applyPayload(this.cache, payload);
      // An answer counts when its payload was taken, or when it carries none for the date asked about.
      const accepted = Boolean(payload) || (Boolean(reply?.done) && !reply.payload && this.date === date);
      if (accepted && reply?.done) this.agendaDone = date;
      // A refusal or a stray changes nothing to draw: the end is watched again.
      if (!accepted) {
        if (this.view === "agenda") this.watchAgendaEnd();
        return;
      }
      // An answer for an agenda the organiser has since left is kept, not drawn.
      if (this.view !== "agenda" || this.date !== date) return;
      if (this.overlayOpen()) this.dirty = true;
      else this.render();
    });
  },

  agendaBusy() {
    return this.agendaLoading > 0 && Date.now() - this.agendaLoading < AGENDA_RETRY_MS;
  },

  agendaFinished(days) {
    return days.length >= AGENDA_MAX_DAYS || this.agendaDone === this.date;
  },

  // Clicks month and agenda add to the hook's own; true when handled.
  viewClick(e) {
    const target = e.target;
    const lens = target.closest("[data-agenda-lens]");
    if (lens) {
      const value = lens.dataset.agendaLens;
      if (AGENDA_LENSES.includes(value) && value !== this.agendaLens) {
        this.agendaLens = value;
        this.render();
      }
      return true;
    }

    if (target.closest("[data-agenda-later]")) {
      this.gotoPeriod("agenda", addDays(this.date, AGENDA_MAX_DAYS));
      return true;
    }

    const more = target.closest("[data-month-more]");
    if (more) {
      const iso = more.dataset.monthMore;
      this.showList(withoutDrafts(eventsForDays(this.cache, [iso])), more, dateLabel(iso, this.strings));
      return true;
    }

    const day = target.closest("[data-month-day], [data-month-cell]");
    if (day && this.el.contains(day)) {
      // On a phone a day is chosen in place: its events show under the grid.
      this.gotoPeriod(this.phone ? "month" : "day", day.dataset.monthDay || day.dataset.monthCell);
      return true;
    }
    return false;
  },

  gotoPeriod(view, date) {
    // The preview (rendered by LiveView) would otherwise stay over the new period.
    if (document.getElementById("calendar-preview")) this.pushEventTo(this.el, "calendar:close_preview", { refocus: "false" });
    this.navigate({ view, date });
    this.pushEventTo(this.el, "calendar:goto", { view, date });
  },

  // Another view, from the period shown (`from`, the pending one if any). A
  // week or a month hands over today or its first day (viewSwitchAnchor); a
  // phone's month keeps the day picked in it.
  switchView(view, from) {
    const today = isoFromDay(Math.floor(this.nowMinute() / MINUTES_PER_DAY));
    const keep = this.phone && from.view === "month";
    this.gotoPeriod(view, keep ? from.date : viewSwitchAnchor(from.view, from.date, today, this.settings.week_start));
  },

  // The days quick create looks in for the next free time: the period in a
  // time view, else the view's date and the six days after it.
  createDays() {
    if (isTimeGrid(this.view)) return periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    return Array.from({ length: CREATE_DAYS }, (_, k) => addDays(this.date, k));
  },

  viewKey(e) {
    const view = VIEW_KEYS[e.key?.toLowerCase?.()];
    if (!view || e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return;
    if (!this.settings || this.drag || this.createDrag || this.moving || this.quick) return;
    const target = e.target;
    if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
    // M on a focused event is the event's own key: the keyboard move (keys.js) or nothing.
    if (view === "month" && target?.closest?.("[data-event-id]") && this.el.contains(target)) return;
    e.preventDefault();
    const from = this.pending ?? { view: this.view, date: this.date };
    if (from.view === view) return;
    this.switchView(view, from);
  },
};
