defmodule TymeslotWeb.E2E.BookerSteps do
  @moduledoc """
  Browser steps through a booking page, for browser tests of the booker's
  layout. They click the theme markup the layout tests care about; a test of
  the booking journey itself belongs in a LiveView test driven by
  `TymeslotWeb.BookingDriver`.
  """

  use Fluffy.Assert

  import Fluffy
  import Fluffy.Locator
  import Fluffy.Playwright, only: [all: 2]

  import TymeslotWeb.E2EHelpers,
    only: [css_in: 2, evaluate_script: 2, evaluate_script: 3, test_id_in: 2]

  @doc """
  Walks the overview to the schedule. Choosing a meeting type is the way on
  (no shipped theme has an overview Next): on a paged theme it shows the
  schedule step; on a continuous page (Folio) it opens the calendar below.
  Either way a day, a time or a slot to pick shows: at its narrowest Quill
  hides the month grid that carries the days' marks and shows the landed
  day's times.

  This is the only entry path that renders the Back button, and so the only one
  that produces the full two-button actions row: a direct booking link sets
  `entered_via_overview: false`, because there is no overview to go back to.
  It is also the journey an embedded booker actually takes.

  Short-viewport tests deliberately deep-link instead. Below roughly 250px of
  usable height the overview's own primary action sits past the end of a page
  that doesn't scroll, so it can't be clicked: a limit of the overview, not of
  the schedule layout those tests guard.
  """
  @spec advance_to_schedule(Fluffy.Session.t()) :: Fluffy.Session.t()
  def advance_to_schedule(session) do
    session =
      session
      |> pick_first("[data-testid='duration-option']")
      |> assert_has(
        by_css("[data-fact='date'], [data-fact='time'], [data-fact='slot']")
        |> filter(visible: true)
        |> first()
      )

    # The Back the overflow checks are meant to prove: one that never
    # rendered would leave only the primary action to measure. A continuous
    # page (Folio) has no page to go back to.
    if all(session, filter(by_css(".journey--continuous"), visible: true)) !=
         [],
       do: session,
       else: assert_has(session, by_test_id("back-step"))
  end

  @doc """
  Picks the first available day and then its first time, leaving the booker
  on the step that follows the schedule. With `frame`, a
  `Fluffy.Locator.frame_locator/1`, it books in the page inside that frame.
  """
  @spec pick_first_slot(Fluffy.Session.t(), Fluffy.FrameLocator.t() | nil) :: Fluffy.Session.t()
  def pick_first_slot(session, frame \\ nil) do
    session
    |> pick_first("[data-testid='calendar-day']:not([disabled])", frame)
    |> pick_first("[data-testid='time-slot']", frame)
    |> click_next_step(frame)
  end

  @doc """
  Fills the booking form with a valid name and email, submits it, and waits
  for the confirmation, clicking submit straight from the email field without
  waiting for the server to see the typed values.
  """
  @spec submit_booking_form(Fluffy.Session.t()) :: Fluffy.Session.t()
  def submit_booking_form(session) do
    session
    |> assert_has(by_test_id("booking-form"))
    |> fill(by_css("input[name='booking[name]']"), "Jane Doe")
    |> fill(by_css("input[name='booking[email]']"), "jane@example.com")
    |> click(by_test_id("submit-booking"))
    |> assert_has(by_test_id("confirmation-heading"))
  end

  @doc """
  Waits for at least one visible element matching `selector`, then clicks the
  first, in the page or inside `frame`.
  """
  @spec pick_first(Fluffy.Session.t(), String.t(), Fluffy.FrameLocator.t() | nil) ::
          Fluffy.Session.t()
  def pick_first(session, selector, frame \\ nil) do
    click(session, css_in(frame, selector) |> filter(visible: true) |> first())
  end

  @doc """
  Clicks the first day on offer, by its `data-fact`, whichever theme renders
  it.
  """
  @spec click_first_free_date(Fluffy.Session.t()) :: Fluffy.Session.t()
  def click_first_free_date(session) do
    click(
      session,
      by_css("[data-fact='date']:not([disabled])") |> filter(visible: true) |> first()
    )
  end

  @doc """
  Clicks the first time on offer, a slot or a time by its `data-fact`.
  """
  @spec pick_first_free_slot(Fluffy.Session.t()) :: Fluffy.Session.t()
  def pick_first_free_slot(session) do
    click(
      session,
      by_css("[data-fact='slot']:not([disabled]), [data-fact='time']:not([disabled])")
      |> filter(visible: true)
      |> first()
    )
  end

  @doc """
  Clicks the first available day that is on screen. Quill shows a week strip
  instead of the month grid on narrow cards, so the month grid's days may be
  in the DOM but hidden.
  """
  @spec pick_first_visible_day(Fluffy.Session.t()) :: Fluffy.Session.t()
  def pick_first_visible_day(session) do
    evaluate_script(session, """
    const day = [...document.querySelectorAll(
      "[data-testid='calendar-day']:not([disabled]), .week-day-cell:not([disabled])"
    )].find((el) => el.offsetParent !== null);
    if (day) day.click();
    """)

    session
  end

  @doc """
  Clicks Next.

  Picking a duration focuses its card, which turns on the booking pages'
  `html:focus-within { scroll-behavior: smooth }`. Where Next sits below the
  fold, the browser scrolls it into view and clicks before the animated scroll
  arrives, so the click misses. An inline style on `<html>` makes that scroll
  instant for this page without touching the stylesheet.
  """
  @spec click_next_step(Fluffy.Session.t(), Fluffy.FrameLocator.t() | nil) :: Fluffy.Session.t()
  def click_next_step(session, frame \\ nil) do
    evaluate_script(session, "document.documentElement.style.scrollBehavior = 'auto';", frame)
    click(session, test_id_in(frame, "next-step"))
  end

  @doc """
  Marks the page as embedded, as `iframe_embed.js` does inside the iframe.
  Setting the attribute on a top-level page exercises the embedded layout rules
  without the embed token and parent-origin handshake.
  """
  @spec mark_embedded(Fluffy.Session.t()) :: Fluffy.Session.t()
  def mark_embedded(session) do
    evaluate_script(session, "document.documentElement.setAttribute('data-embedded', '');")
    session
  end
end
