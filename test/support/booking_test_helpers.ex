defmodule Tymeslot.BookingTestHelpers do
  @moduledoc """
  Test helpers for booking flow navigation and common booking test operations.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint TymeslotWeb.Endpoint

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
  def navigate_to_booking_form(conn, profile, _event_type) do
    timezone = profile.timezone
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

    # Select the first meeting type
    view |> element("button[data-testid='duration-option']") |> render_click()

    # Navigate to date/time selection
    view |> element("button[data-testid='next-step']") |> render_click()

    # Wait for availability to load and select an available date
    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()

    # Wait for time slots to load
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    # Extract and click the first available time slot
    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()

    # Navigate to the booking form
    view |> element("button[phx-click='next_step']") |> render_click()

    view
  end

  defp wait_until(fun, timeout \\ 5000) do
    if timeout <= 0 do
      fun.() || flunk("Timed out waiting for condition")
    else
      if fun.() do
        :ok
      else
        Process.sleep(100)
        wait_until(fun, timeout - 100)
      end
    end
  end
end
