defmodule TymeslotWeb.Live.Scheduling.ScheduleInteractionTest do
  @moduledoc """
  Pins the state-clearing rules that the schedule step must honour when
  the user re-traverses decisions — re-selecting a date, toggling a
  time slot back off, and typing boundary values into the timezone
  search. These are the interactions where a regression would most
  likely manifest as the next-step button enabling over stale state
  (i.e. a submittable booking with no actual selection).

  Two test surfaces:

    * **LiveView integration** — drives the Quill theme through the
      real scheduling flow and asserts next-step stays disabled after
      the user re-selects the date.
    * **Handler unit** — exercises the timezone search handler's
      boundary inputs (empty string, special characters) directly;
      the existing handler test only covers the three valid param
      shapes.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  setup :verify_on_exit!

  describe "schedule step — LiveView interaction" do
    setup tags do
      Mox.set_mox_from_context(tags)
      RateLimiter.clear_all()
      AvailabilityCache.clear_all()
      TestMocks.setup_all_mocks()

      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "schedrepick",
          booking_theme: "1",
          timezone: "America/New_York",
          advance_booking_days: 30,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Quick Chat",
        is_active: true
      )

      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      insert(:calendar_integration, user: user, is_active: true)

      %{profile: profile}
    end

    @tag :capture_log
    test "re-selecting the date clears the picked time and disables next-step",
         %{conn: conn, profile: profile} do
      timezone = profile.timezone
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

      # Overview → schedule.
      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      today = timezone |> DateTime.now!() |> DateTime.to_date()
      target = Date.add(today, 1)

      if target.month != today.month do
        view |> element("button[phx-click='next_month']") |> render_click()
      end

      date_str = Date.to_string(target)

      wait_until(fn ->
        has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
      end)

      view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      slot =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("button.time-slot-button", "phx-value-time")
        |> List.first() ||
          flunk("Expected at least one available time slot button after selecting a date")

      view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()

      # After picking both date and time the next-step button must not
      # be disabled — this pins the healthy baseline before the
      # regression-triggering interaction.
      refute has_next_step_disabled?(view)

      # Re-click the same calendar day. The shared scheduling core
      # (`handle_schedule_date_selection/2`) clears selected_time on
      # every date click — without this, the user would land on the
      # booking form with a stale time the UI no longer displays.
      view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()

      assert has_next_step_disabled?(view)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.selected_time == nil
    end
  end

  describe "timezone search — boundary inputs" do
    test "empty string search collapses to an empty search term without crashing" do
      socket = %Socket{assigns: %{__changed__: %{}, timezone_dropdown_open: false}}

      {:ok, updated} = TimezoneHandlerComponent.handle_timezone_search(socket, %{"search" => ""})

      assert updated.assigns.timezone_search == ""
      # Typing opens the dropdown even when the user clears the input —
      # otherwise clearing a query would hide the full list the user
      # is trying to re-browse.
      assert updated.assigns.timezone_dropdown_open == true
    end

    test "unknown param shape falls back to an empty search term" do
      # Real LiveView clients have pushed shapes the handler doesn't
      # recognise (e.g. from extension-injected forms). The fallback
      # must not crash the process.
      socket = %Socket{assigns: %{__changed__: %{}}}

      {:ok, updated} =
        TimezoneHandlerComponent.handle_timezone_search(socket, %{"nonsense" => "value"})

      assert updated.assigns.timezone_search == ""
      assert updated.assigns.timezone_dropdown_open == true
    end

    test "search preserves special characters verbatim" do
      socket = %Socket{assigns: %{__changed__: %{}}}

      special = "São Paulo — <script>"

      {:ok, updated} =
        TimezoneHandlerComponent.handle_timezone_search(socket, %{"search" => special})

      assert updated.assigns.timezone_search == special
    end
  end

  defp has_next_step_disabled?(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("button[data-testid='next-step'][disabled]")
    |> Enum.any?()
  end
end
