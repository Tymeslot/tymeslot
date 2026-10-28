defmodule TymeslotWeb.E2E.BookerLayoutAssertions do
  @moduledoc """
  Layout assertions on a booking page in a real browser, for the embed and
  short-viewport layout tests. Each measures the page with a script and returns
  the session, so it pipes; `context` names the theme, step and size, and is
  quoted in the failure message.
  """

  import ExUnit.Assertions
  import TymeslotWeb.E2EHelpers, only: [evaluate_script: 2]

  # Sub-pixel rounding in the WebDriver bridge can show a measurement one px
  # over the viewport even when the element fits. `E2EHelpers` carries its own
  # copy for `assert_no_horizontal_overflow/2`: the tolerance is a property of
  # the bridge, not of either module.
  @overflow_tolerance 1

  @doc """
  The schedule actions row sits fully inside the viewport.

  Stronger than `assert_cta_reachable/2`: on the bounded-card model of an
  app-shell theme the pinned actions must stay on-screen at short heights,
  proving the calendar scrolls internally rather than pushing the buttons off.

  Measures the row rather than the individual buttons: Back only exists when
  the booker came via the overview, but the row it lives in is what has to stay
  pinned, and both buttons share its vertical extent.
  """
  @spec assert_actions_within_viewport(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_actions_within_viewport(session, context) do
    value =
      evaluate_script(session, """
      const actions = document.querySelector("[data-testid='schedule-actions']");
      if (!actions) return null;
      const a = actions.getBoundingClientRect();
      return [Math.round(a.top), Math.round(a.bottom), window.innerHeight];
      """)

    assert is_list(value), "schedule actions not found at #{context}"
    [top, bottom, inner_h] = value

    assert top >= -@overflow_tolerance and bottom <= inner_h + @overflow_tolerance,
           "The schedule actions row is outside the viewport at #{context} " <>
             "(top=#{top}, bottom=#{bottom}, viewport=#{inner_h}): the bounded " <>
             "schedule card should keep it pinned on-screen."

    session
  end

  @doc """
  The document is no taller than the viewport (a couple of px of WebDriver
  rounding tolerated).

  Regression guard for the "double overflow": a viewport-locked schedule step
  must scroll only inside the calendar, never the page on top of it.
  """
  @spec assert_no_vertical_page_scroll(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_no_vertical_page_scroll(session, context) do
    [scroll_height, inner_height] =
      evaluate_script(
        session,
        "return [document.documentElement.scrollHeight, window.innerHeight];"
      )

    assert scroll_height <= inner_height + 2,
           """
           Page scrolls vertically at #{context} (double overflow):
             document scrollHeight = #{scroll_height}px
             viewport innerHeight  = #{inner_height}px
           The schedule step should lock to the viewport and scroll only inside
           the calendar.
           """

    session
  end

  @doc """
  No element of the booker scrolls on its own.

  An embedded booker has one scroll region, the host page: an inner scroller
  keeps content out of sight inside an iframe that should have grown instead.
  """
  @spec assert_no_inner_scroll_region(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_no_inner_scroll_region(session, context) do
    scrolling =
      evaluate_script(session, """
      return [...document.querySelectorAll("[data-booker-root] *")]
        .filter((el) => {
          const overflowY = getComputedStyle(el).overflowY;
          return (overflowY === "auto" || overflowY === "scroll") &&
            el.scrollHeight > el.clientHeight + 1;
        })
        .map((el) => `${el.className} (${el.clientHeight}px showing ${el.scrollHeight}px)`);
      """)

    assert scrolling == [],
           "#{context}: the booker scrolls inside itself instead of growing the " <>
             "iframe: #{Enum.join(scrolling, "; ")}. The schedule step must not " <>
             "lock to the viewport in an embed."

    session
  end

  @doc """
  The calendar a fixed-date type shows below its list of dates is never a
  scroll region of its own while it overflows: whatever scrolls it (an element
  of the card, or the page) scrolls the list too.
  """
  @spec assert_calendar_scrolls_with_session_list(Wallaby.Session.t(), String.t()) ::
          Wallaby.Session.t()
  def assert_calendar_scrolls_with_session_list(session, context) do
    value =
      evaluate_script(session, """
      // A week strip's day where the month grid is hidden (Quill, short).
      const day = [...document.querySelectorAll("[data-testid='calendar-day'], .week-day-cell")]
        .find((el) => el.offsetParent !== null);
      const list = document.querySelector("[data-testid='session-list']");
      if (!day || !list) return "missing";
      for (let el = day.parentElement; el && el !== document.body; el = el.parentElement) {
        const overflowY = getComputedStyle(el).overflowY;
        const scrolls = overflowY === "auto" || overflowY === "scroll";
        if (scrolls && el.scrollHeight > el.clientHeight + 1) {
          return el.contains(list) ? "shared" : el.className;
        }
      }
      return "shared";
      """)

    refute value == "missing", "#{context}: no visible calendar day, or no session list"

    assert value == "shared",
           "The calendar scrolls on its own below the list of dates at #{context} " <>
             "(scroll region: #{inspect(value)}), so the list squeezes it; the " <>
             "dates and the calendar should scroll together."

    session
  end

  @doc """
  The schedule actions row does not overlap the calendar.

  Guards the wide-short schedule fix: the layout must not let the calendar
  overflow its card and paint over the actions row. A week grid's navigation
  row stands in for the calendar's first day: it sits at the top of the picker,
  as that day does, and is there before the week's times load.
  """
  @spec assert_no_actions_calendar_overlap(Wallaby.Session.t(), String.t()) ::
          Wallaby.Session.t()
  def assert_no_actions_calendar_overlap(session, context) do
    overlap =
      evaluate_script(session, """
      const actions = document.querySelector("[data-testid='schedule-actions']");
      const day = document.querySelector("[data-testid='calendar-day'], .week-grid__nav");
      if (!actions || !day) return "missing";
      const a = actions.getBoundingClientRect(), c = day.getBoundingClientRect();
      // overlap iff the rects intersect on both axes
      return !(a.right <= c.left || a.left >= c.right || a.bottom <= c.top || a.top >= c.bottom);
      """)

    # Nothing to compare would let the check pass without testing anything.
    refute overlap == "missing",
           "#{context}: no schedule actions row, or neither calendar days nor a week grid's navigation"

    refute overlap,
           "The schedule actions row overlaps the calendar at #{context}: the " <>
             "schedule card is clipping/overflowing instead of growing to its " <>
             "natural height."

    session
  end

  @doc """
  The primary CTA lives inside the scrollable page (reachable by scrolling),
  not clipped beyond the document's scroll height.
  """
  @spec assert_cta_reachable(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_cta_reachable(session, context) do
    value =
      evaluate_script(session, """
      const cta = document.querySelector("[data-testid='next-step']");
      if (!cta) return null;
      const r = cta.getBoundingClientRect();
      return [Math.round(r.bottom + window.scrollY), r.height, document.documentElement.scrollHeight];
      """)

    assert is_list(value), "next-step CTA not found at #{context}"
    [cta_doc_bottom, cta_height, scroll_height] = value

    assert cta_height > 0, "next-step CTA has zero height at #{context}"

    assert cta_doc_bottom <= scroll_height + @overflow_tolerance,
           "next-step CTA at #{context} sits below the document scroll height " <>
             "(#{cta_doc_bottom}px > #{scroll_height}px): it is clipped and unreachable."

    session
  end

  @doc """
  On a page whose booking content fits the viewport, the branding banner sits
  inside the viewport, not pushed past 100vh by the content area's centering
  padding.
  """
  @spec assert_branding_footer_within_viewport(Wallaby.Session.t(), String.t()) ::
          Wallaby.Session.t()
  def assert_branding_footer_within_viewport(session, context) do
    value =
      evaluate_script(session, """
      const f = document.querySelector('.branding-footer');
      if (!f) return null;
      return [Math.round(f.getBoundingClientRect().bottom), window.innerHeight];
      """)

    assert is_list(value), "branding footer not found at #{context}"
    [foot_bottom, inner_h] = value

    assert foot_bottom <= inner_h + @overflow_tolerance,
           "Branding banner overflows the viewport at #{context}: banner bottom " <>
             "#{foot_bottom}px > viewport #{inner_h}px. Content fits, so the banner " <>
             "must share the viewport (see the :has(.branding-footer) rule)."

    session
  end

  @doc """
  The booking form's name and email fields sit one above the other.
  """
  @spec assert_name_email_stacked(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_name_email_stacked(session, context) do
    positions =
      evaluate_script(session, """
      const name = document.querySelector("input[name='booking[name]']");
      const email = document.querySelector("input[name='booking[email]']");
      if (!name || !email) return null;
      return [name.getBoundingClientRect().top, email.getBoundingClientRect().top];
      """)

    assert is_list(positions), "#{context}: the name and email fields are not in the DOM"
    [name_top, email_top] = positions

    assert email_top > name_top,
           "Name and email did not stack at #{context} " <>
             "(name_top=#{name_top}, email_top=#{email_top}). " <>
             "`.booking-inline-fields` should collapse to one column."

    session
  end

  @doc """
  The confirmation's location entry is not clipped: its content is no wider
  than the entry. The ticket body clips its overflow, so a squeezed entry
  loses its label silently.
  """
  @spec assert_location_entry_unclipped(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_location_entry_unclipped(session, context) do
    widths =
      evaluate_script(session, """
      const row = document.querySelector("[data-testid='confirmation-location']");
      if (!row) return null;
      return [row.scrollWidth, row.clientWidth];
      """)

    assert is_list(widths), "#{context}: the confirmation location entry is not in the DOM"
    [scroll_w, client_w] = widths

    assert scroll_w <= client_w + @overflow_tolerance,
           "#{context}: the location entry's content is #{scroll_w}px wide in a " <>
             "#{client_w}px entry, so the ticket body clips it. The arranged-note " <>
             "row needs a flex basis that wraps it onto its own line."

    session
  end
end
