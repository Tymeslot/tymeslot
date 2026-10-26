defmodule TymeslotWeb.E2E.BookerSteps do
  @moduledoc """
  Browser steps through a booking page, for Wallaby tests of the booker's
  layout. They click the theme markup the layout tests care about; a test of
  the booking journey itself belongs in a LiveView test driven by
  `TymeslotWeb.BookingDriver`.
  """

  import Wallaby.Browser
  import Wallaby.Query

  alias Wallaby.Element

  @doc """
  Walks the overview to the schedule step: picks the first duration, then Next.

  This is the only entry path that renders the Back button, and so the only one
  that produces the full two-button actions row: a direct booking link sets
  `entered_via_overview: false`, because there is no overview to go back to.
  It is also the journey an embedded booker actually takes.

  Short-viewport tests deliberately deep-link instead. Below roughly 250px of
  usable height the overview's own CTA sits past the end of a page that doesn't
  scroll, so it can't be clicked: a limit of the overview, not of the schedule
  layout those tests guard.
  """
  @spec advance_to_schedule(Wallaby.Session.t()) :: Wallaby.Session.t()
  def advance_to_schedule(session) do
    session
    |> pick_first("[data-testid='duration-option']")
    # Both themes disable Next until the selected duration round-trips to the
    # server. Clicking it before then is a no-op, so wait for it to enable.
    |> assert_has(css("[data-testid='next-step']:not([disabled])"))
    |> click_next_step()
    |> assert_has(css("[data-testid='back-step']"))
  end

  @doc """
  Picks the first available day and then its first time, leaving the booker
  on the step that follows the schedule.
  """
  @spec pick_first_slot(Wallaby.Session.t()) :: Wallaby.Session.t()
  def pick_first_slot(session) do
    session
    |> pick_first("[data-testid='calendar-day']:not([disabled])")
    |> pick_first("[data-testid='time-slot']")
    |> click_next_step()
  end

  @doc """
  Fills the booking form with a valid name and email, submits it, and waits
  for the confirmation. The fields validate on blur, so the last one is blurred
  before waiting for the submit button to enable.
  """
  @spec submit_booking_form(Wallaby.Session.t()) :: Wallaby.Session.t()
  def submit_booking_form(session) do
    session
    |> assert_has(css("[data-testid='booking-form']"))
    |> fill_in(css("input[name='booking[name]']"), with: "Jane Doe")
    |> fill_in(css("input[name='booking[email]']"), with: "jane@example.com")
    |> execute_script("document.activeElement.blur()")
    |> assert_has(css("[data-testid='submit-booking']:not([disabled])"))
    |> click(css("[data-testid='submit-booking']"))
    |> assert_has(css("[data-testid='confirmation-heading']"))
  end

  @doc """
  Waits for at least one element matching `selector`, then clicks the first.
  """
  @spec pick_first(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def pick_first(session, selector) do
    session
    |> assert_has(css(selector, minimum: 1))
    |> find(css(selector, count: :any))
    |> List.first()
    |> Element.click()

    session
  end

  @doc """
  Clicks the first available day that is on screen. Quill shows a week strip
  instead of the month grid on narrow cards, so the month grid's days may be
  in the DOM but hidden.
  """
  @spec pick_first_visible_day(Wallaby.Session.t()) :: Wallaby.Session.t()
  def pick_first_visible_day(session) do
    execute_script(session, """
    const day = [...document.querySelectorAll(
      "[data-testid='calendar-day']:not([disabled]), .week-day-cell:not([disabled])"
    )].find((el) => el.offsetParent !== null);
    if (day) day.click();
    """)
  end

  @doc """
  Clicks Next.

  Picking a duration focuses its card, which turns on the booking pages'
  `html:focus-within { scroll-behavior: smooth }`. Where Next sits below the
  fold, chromedriver scrolls it into view and clicks before the animated scroll
  arrives, so the click misses. An inline style on `<html>` makes that scroll
  instant for this page without touching the stylesheet.
  """
  @spec click_next_step(Wallaby.Session.t()) :: Wallaby.Session.t()
  def click_next_step(session) do
    session
    |> execute_script("document.documentElement.style.scrollBehavior = 'auto';")
    |> click(css("[data-testid='next-step']"))
  end

  @doc """
  Marks the page as embedded, as `iframe_embed.js` does inside the iframe.
  Setting the attribute on a top-level page exercises the embedded layout rules
  without the embed token and parent-origin handshake.
  """
  @spec mark_embedded(Wallaby.Session.t()) :: Wallaby.Session.t()
  def mark_embedded(session) do
    execute_script(session, "document.documentElement.setAttribute('data-embedded', '');")
  end
end
