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

  alias Ecto.Changeset
  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
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
          timezone: "America/New_York"
        )

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
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
          schedule: schedule,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      insert(:calendar_integration, user: user, is_active: true)

      %{profile: profile, user: user}
    end

    @tag :capture_log
    test "a meeting type on a longer schedule widens the window past the default",
         %{conn: conn, profile: profile, user: user} do
      # The window disables the calendar's forward navigation, so reading it from
      # the default schedule alone would put this type's later dates out of
      # reach: 180 days of bookable time behind a 30-day wall.
      long_schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: false,
          name: "Long lead time",
          advance_booking_days: 180,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          schedule: long_schedule,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true,
        availability_schedule_id: long_schedule.id
      )

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view
      |> element("button[data-testid='duration-option'][phx-value-duration='deep-dive']")
      |> render_click()

      view |> element("button[data-testid='next-step']") |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.booking_window_days == 180
    end

    @tag :capture_log
    test "advertises the booking window from the organiser's default schedule",
         %{conn: conn, profile: profile} do
      # The window is resolved once at mount and assigned, so the theme never
      # reads it off the profile. The fixture's default schedule allows 30 days,
      # which must win over the 90-day fallback used when a profile has none.
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.booking_window_days == 30

      html = render(view)
      assert html =~ "1 month in advance"
      refute html =~ "90 days in advance"
    end

    # The slot fetch's `{:error, _}` branch had no test at all, so the message
    # it puts on the most conversion-critical screen in the product was free to
    # regress — including back into the internal wording it used to carry
    # ("calendar parsing error"), which tells a booker nothing they can act on.
    @tag :capture_log
    test "a calendar the host's provider cannot serve shows the booker an actionable message",
         %{conn: conn, profile: profile} do
      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :all_calendars_unavailable}
      end)

      timezone = profile.timezone
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

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

      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:calendar_error] != nil end)

      html = render(view)

      # Asserted on the rendered page, not the assign: the assign was always
      # set, and what makes this a user-facing bug is the sentence the booker
      # reads while the funnel is failing.
      assert html =~ "No time slots could be loaded. Please try again."
      refute html =~ "calendar parsing error"

      state = :sys.get_state(view.pid).socket.assigns

      # The spinner is cleared and the list emptied, so the page settles on
      # the message rather than on a load that never finishes.
      assert state.available_slots == []
      refute state.loading_slots
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

    @tag :capture_log
    test "calendar days carry full date labels and a live region announces slot loading",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      html = render(view)

      labels =
        html |> Floki.parse_document!() |> Floki.attribute("button.calendar-day", "aria-label")

      # Screen readers hear a full date, not a bare day number.
      assert labels != []

      assert Enum.any?(
               labels,
               &(&1 =~ ~r/(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), .+ \d{4}$/)
             )

      # Today's calendar day is marked as the current date for AT users.
      assert html
             |> Floki.parse_document!()
             |> Floki.find("button.calendar-day[aria-current='date']")
             |> Enum.any?()

      # A polite live region announces the slot-loading state. The schedule
      # step now opens on the first bookable day, so the region carries slot
      # state rather than the "pick a date" prompt. The prompt is not dead: no
      # click reaches it any more, but a fetch that fails or a search that
      # finds nothing still leaves the step with no day selected.
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      refute html =~ "Please select a date to see available times"
    end

    @tag :capture_log
    test "Rhythm theme renders day labels and the live region on the schedule step",
         %{conn: conn, profile: profile} do
      profile
      |> Changeset.change(booking_theme: "2")
      |> Repo.update!()

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      html = render(view)

      labels =
        html |> Floki.parse_document!() |> Floki.attribute("button.calendar-day", "aria-label")

      assert labels != []

      assert Enum.any?(
               labels,
               &(&1 =~ ~r/(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), .+ \d{4}$/)
             )

      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      refute html =~ "Please select a date to see available times"
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
