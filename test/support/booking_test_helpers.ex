defmodule Tymeslot.BookingTestHelpers do
  @moduledoc """
  Test helpers for booking flow navigation and common booking test operations.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Tymeslot.TestHelpers.Eventually
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @endpoint TymeslotWeb.Endpoint

  # Select on `data-testid`, not on CSS classes. Quill and Rhythm agree on the
  # test ids but not on the classes behind them — Quill's time slots are
  # `.time-slot-button`, Rhythm's are `.time-slot` — so a class-based walk
  # silently only ever worked on Quill.
  @duration_option "button[data-testid='duration-option']"
  @next_step "button[data-testid='next-step']"
  @calendar_day "button[data-testid='calendar-day']"
  @time_slot "button[data-testid='time-slot']"
  # Quill paginates the date grid by month, Rhythm by week, and neither theme
  # renders the other's control. Reaching for Quill's unconditionally is what
  # made every Rhythm walk raise on the last day of a month: the one day where
  # tomorrow falls outside the range already on screen.
  @next_month "button[phx-click='next_month']"
  @prev_month "button[phx-click='prev_month']"
  @month_label ".calendar-month-label"
  @next_week "button[phx-click='next_week']"

  @doc """
  Navigates through the complete booking flow from profile page to booking form.

  This helper performs the following steps:
  1. Visits the profile page
  2. Selects the first meeting type
  3. Navigates to date/time selection
  4. Waits for availability to load
  5. Selects tomorrow's date
  6. Waits for time slots
  7. Selects the first available time slot
  8. Navigates to the booking form

  Returns the LiveView at the booking form step.

  ## Examples

      view = navigate_to_booking_form(conn, profile, event_type)
      # Now you can submit the booking form
  """
  @spec navigate_to_booking_form(Plug.Conn.t(), struct(), struct()) ::
          Phoenix.LiveViewTest.View.t()
  def navigate_to_booking_form(conn, profile, event_type),
    do: navigate_to_booking_form(conn, profile, event_type, [])

  @doc """
  As `navigate_to_booking_form/3`, with extra query params merged into the
  scheduling page URL.

  The reschedule journey needs `reschedule_meeting_uid` present from the first
  render — `LiveHelpers` reads it out of the params to set `is_rescheduling`,
  and without it the identical walk silently books a *new* meeting instead of
  moving the existing one.
  """
  @spec navigate_to_booking_form(Plug.Conn.t(), struct(), struct(), keyword() | list()) ::
          Phoenix.LiveViewTest.View.t()
  def navigate_to_booking_form(conn, profile, _event_type, query_params) do
    timezone = profile.timezone
    query = URI.encode_query([{"timezone", timezone} | Enum.to_list(query_params)])
    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    walk_to_booking_form(view, timezone)
  end

  @doc """
  Walks an already-mounted scheduling view from the overview step through to
  the booking form, which is what `navigate_to_booking_form/4` does once it has
  mounted one of its own.

  Public because the flow can restart without a mount to hang off: "Schedule
  Another Meeting" returns the same LiveView to the overview step in place, and
  the walk that follows has to start from the view already on screen.

  `duration_slug` names the card to book, defaulting to whichever the overview
  lists first.
  """
  @spec walk_to_booking_form(Phoenix.LiveViewTest.View.t(), String.t(), String.t() | nil) ::
          Phoenix.LiveViewTest.View.t()
  def walk_to_booking_form(view, timezone, duration_slug \\ nil) do
    select_meeting_type(view, duration_slug)

    # Navigate to date/time selection
    view |> element(@next_step) |> render_click()

    # Wait for availability to load and select an available date
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)

    advance_calendar_to(view, target_date)

    wait_until(fn -> has_element?(view, "#{day_selector(target_date)}:not([disabled])") end)

    view |> element(day_selector(target_date)) |> render_click()

    # Wait for time slots to load
    wait_until(fn -> has_element?(view, @time_slot) end)

    # Extract and click the first available time slot
    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute(@time_slot, "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view |> element("#{@time_slot}[phx-value-time='#{slot}']") |> render_click()

    # Navigate to the booking form
    view |> element(@next_step) |> render_click()

    view
  end

  # Picking by slug rather than by `element(@duration_option)`: an organiser
  # offering more than one type renders more than one card, and an ambiguous
  # selector is refused outright rather than resolved to the first match.
  defp select_meeting_type(view, nil) do
    slug =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute(@duration_option, "phx-value-duration")
      |> List.first() ||
        flunk("Expected at least one meeting type card on the overview step")

    select_meeting_type(view, slug)
  end

  defp select_meeting_type(view, duration_slug) do
    view
    |> element("#{@duration_option}[phx-value-duration='#{duration_slug}']")
    |> render_click()
  end

  # Bring `target_date` into the displayed range, driving whichever control the
  # rendered theme actually offers.
  defp advance_calendar_to(view, target_date) do
    wait_until(fn -> has_element?(view, @calendar_day) end)

    cond do
      has_element?(view, @next_month) -> show_month(view, target_date, :next)
      has_element?(view, @next_week) -> advance_week(view, target_date)
      true -> :ok
    end
  end

  @doc """
  Brings `date`'s month onto Quill's month grid, stepping one month towards
  `direction` (`:next` or `:prev`) only if the grid is not showing it already.

  The only way to move the month in a booking test. The schedule step opens on
  the first bookable day, so whether the grid still shows today's month depends
  on the hour and the day of the month the suite happens to run on; see
  `showing_month?/2` for what goes wrong when the step is computed instead.
  Two directions because two questions get asked: a walk towards a later date
  steps forward, and a test about today's own cell steps back to it.

  Asserts the month is on screen afterwards, so an overshoot or a step the
  wrong way fails here, by name, rather than as a five-second `wait_until`
  timeout further down.
  """
  @spec show_month(Phoenix.LiveViewTest.View.t(), Date.t(), :next | :prev) :: :ok
  def show_month(view, %Date{} = date, direction \\ :next) when direction in [:next, :prev] do
    unless showing_month?(view, date) do
      view |> element(month_arrow(direction)) |> render_click()
    end

    assert showing_month?(view, date),
           "expected the calendar to show #{Calendar.strftime(date, "%B %Y")} " <>
             "after at most one step #{direction}"

    :ok
  end

  defp month_arrow(:next), do: @next_month
  defp month_arrow(:prev), do: @prev_month

  @doc """
  Whether the month grid is currently displaying `date`'s month.

  Public because every booking walk needs this question answered, and answering
  it by arithmetic is wrong. The schedule step opens on the first bookable day,
  so on the last day of a month, once today's cutoff has passed, the grid is
  already showing the next month before any navigation happens. A guard written
  as `if target.month != today.month` then advances a calendar that has moved
  itself: either the arrow is disabled at the far edge of the booking window and
  the click raises, or it succeeds and overshoots, leaving the target behind.

  Quill's grid pads with the neighbouring month's days and disables them, so a
  rendered day cell proves nothing about which month is on screen. The month
  label does, which is what this reads.
  """
  @spec showing_month?(Phoenix.LiveViewTest.View.t(), Date.t()) :: boolean()
  def showing_month?(view, %Date{} = date) do
    has_element?(
      view,
      @month_label,
      LocalizationHelpers.get_month_year_display(date.year, date.month)
    )
  end

  # Rhythm's strip renders exactly the seven days it offers and no padding, so
  # a missing cell is proof the date sits in a later week.
  defp advance_week(view, target_date) do
    day = day_selector(target_date)

    if has_element?(view, day) do
      :ok
    else
      view |> element(@next_week) |> render_click()
      wait_until(fn -> has_element?(view, day) end)
    end
  end

  defp day_selector(date), do: "#{@calendar_day}[phx-value-date='#{Date.to_string(date)}']"

  defp wait_until(fun, timeout \\ 5000) do
    Eventually.eventually(fun, timeout: timeout, interval: 100)
  end
end
