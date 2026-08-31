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

    # Select the first meeting type
    view |> element(@duration_option) |> render_click()

    # Navigate to date/time selection
    view |> element(@next_step) |> render_click()

    # Wait for availability to load and select an available date
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)

    advance_calendar_to(view, today, target_date)

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

  # Bring `target_date` into the displayed range, driving whichever control the
  # rendered theme actually offers.
  defp advance_calendar_to(view, today, target_date) do
    wait_until(fn -> has_element?(view, @calendar_day) end)

    cond do
      has_element?(view, @next_month) -> advance_month(view, today, target_date)
      has_element?(view, @next_week) -> advance_week(view, target_date)
      true -> :ok
    end
  end

  # Quill's month grid pads with the neighbouring month's days and disables
  # them, so a rendered cell is no proof the date is bookable here: the month
  # itself is what has to move.
  #
  # Read the month the calendar is actually showing rather than assuming it
  # opened on today's. The schedule step opens on the next available day, which
  # is not always in today's month -- on the last day of a month it is already
  # showing the next one, and advancing again would leave the target behind and
  # land on a month the booking window forbids.
  defp advance_month(view, _today, target_date) do
    unless showing_month?(view, target_date) do
      view |> element(@next_month) |> render_click()
    end
  end

  defp showing_month?(view, %Date{} = date) do
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
