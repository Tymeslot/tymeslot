defmodule Tymeslot.BookingTestHelpers do
  @moduledoc """
  Test helpers for booking flow navigation and common booking test operations.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Tymeslot.TestHelpers.Eventually

  @endpoint TymeslotWeb.Endpoint

  # Select on `data-testid`, not on CSS classes. Quill and Rhythm agree on the
  # test ids but not on the classes behind them — Quill's time slots are
  # `.time-slot-button`, Rhythm's are `.time-slot` — so a class-based walk
  # silently only ever worked on Quill.
  @duration_option "button[data-testid='duration-option']"
  @next_step "button[data-testid='next-step']"
  @calendar_day "button[data-testid='calendar-day']"
  @time_slot "button[data-testid='time-slot']"

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
    date_str = Date.to_string(target_date)

    # Navigate to next month if tomorrow falls outside the currently displayed month
    if target_date.month != today.month || target_date.year != today.year do
      view |> element("button[phx-click='next_month']") |> render_click()
    end

    wait_until(fn ->
      has_element?(view, "#{@calendar_day}[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("#{@calendar_day}[phx-value-date='#{date_str}']") |> render_click()

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

  defp wait_until(fun, timeout \\ 5000) do
    Eventually.eventually(fun, timeout: timeout, interval: 100)
  end
end
