defmodule TymeslotWeb.Live.Scheduling.NextAvailableTest do
  @moduledoc """
  Pins the schedule step opening on a bookable day rather than an empty
  grid.

  The assertions are deliberately made against rendered output. Storing
  `selected_date` is not the feature — painting a selected day and the
  times that go with it is, and asserting only on the assign would pass
  even if no component ever received the selection.

  Three behaviours are covered, because each fails differently:

    * the common case, where today's month has a free day;
    * a month blacked out entirely, where the search has to move the
      window forward and the booker must land on a *later* month;
    * a date carried in on the URL, which is a deliberate choice and
      must survive untouched.

  The unit tests below cover the boundaries that are awkward to provoke
  through the UI — a past date sitting in the map, and a fetch that
  failed rather than returned an empty month.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.NextAvailable

  setup :verify_on_exit!

  describe "landing on the first available day" do
    setup tags do
      Mox.set_mox_from_context(tags)
      RateLimiter.clear_all()
      AvailabilityCache.clear_all()
      TestMocks.setup_all_mocks()

      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "nextavail",
          booking_theme: "1",
          timezone: "America/New_York"
        )

      # The booking window and the notice period live on the availability
      # schedule, not the profile, and weekly availability hangs off that
      # schedule — attaching it to the profile would leave the booker with no
      # free day at all and the assertions below would pass over nothing.
      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          advance_booking_days: 90,
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

      %{profile: profile, user: user, schedule: schedule}
    end

    @tag :capture_log
    test "the schedule step opens with a day selected and its times already listed",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      # The slot list arrives on a follow-up message, exactly as it does
      # after a manual day click.
      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      html = render(view)
      document = Floki.parse_document!(html)

      # A day is painted as selected. Without this the booker sees a grid
      # with nothing chosen, which is the state this change removes.
      selected = Floki.find(document, "button.calendar-day--selected")

      assert selected != [],
             "expected a calendar day to render as selected on entering the schedule step"

      # ...and it is the day the flow actually holds, not a stale paint.
      state = :sys.get_state(view.pid).socket.assigns
      assert {:ok, %Date{}} = Date.from_iso8601(state.selected_date)
      assert html =~ state.selected_date

      # The times for that day are on screen, so the booker's next action
      # is picking a time rather than hunting for a day.
      slots = Floki.attribute(document, "button.time-slot-button", "phx-value-time")
      assert slots != [], "expected the auto-selected day's slots to be rendered"

      # No time is pre-picked — choosing the hour stays the booker's decision.
      assert state.selected_time == nil
      assert next_step_disabled?(view)
    end

    @tag :capture_log
    test "a fully blacked-out month advances the window to a month that has availability",
         %{conn: conn, profile: profile, schedule: schedule} do
      timezone = profile.timezone
      today = timezone |> DateTime.now!() |> DateTime.to_date()

      # Black out every remaining day of the current month, plus the
      # leading days of the next month that the 42-day display range
      # reaches, so the first free day is genuinely in a later month.
      blackout_end = today |> Date.end_of_month() |> Date.add(14)

      Enum.each(Date.range(today, blackout_end), fn date ->
        insert(:availability_override,
          schedule: schedule,
          date: date,
          override_type: "unavailable"
        )
      end)

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      wait_until(fn ->
        :sys.get_state(view.pid).socket.assigns[:selected_date] != nil
      end)

      state = :sys.get_state(view.pid).socket.assigns
      {:ok, landed_on} = Date.from_iso8601(state.selected_date)

      # The booker is past the blackout, not parked on a dead month.
      assert Date.compare(landed_on, blackout_end) == :gt,
             "expected to land after the blackout, got #{state.selected_date}"

      # The visible month moved with the selection — a selected day the
      # grid is not showing would be invisible to the booker.
      assert state.current_month == landed_on.month
      assert state.current_year == landed_on.year

      assert render(view) =~ state.selected_date
    end

    @tag :capture_log
    test "a date supplied in the URL is kept instead of being overwritten",
         %{conn: conn, profile: profile} do
      timezone = profile.timezone
      today = timezone |> DateTime.now!() |> DateTime.to_date()

      # Far enough out to be a different day from any auto-selection.
      chosen = Date.add(today, 21)
      chosen_string = Date.to_string(chosen)

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat?timezone=#{timezone}&date=#{chosen_string}"
        )

      wait_until(fn ->
        :sys.get_state(view.pid).socket.assigns[:selected_date] != nil
      end)

      state = :sys.get_state(view.pid).socket.assigns

      assert state.selected_date == chosen_string,
             "a date named in the URL must survive the auto-selection"
    end

    @tag :capture_log
    test "a URL date's slots are not overwritten by a fetch for the auto-picked day",
         %{conn: conn, profile: profile, schedule: schedule} do
      # `mount` enters the schedule step before `handle_params` applies the
      # URL, so the auto-selection ran against an empty `selected_date`, chose
      # today, and fired a slot fetch for it. That late result landed on top of
      # the requested day's slots — the booker saw the right date highlighted
      # above the wrong day's times. Asserting on `selected_date` alone misses
      # this entirely, because the assign was always correct.
      timezone = profile.timezone
      today = timezone |> DateTime.now!() |> DateTime.to_date()

      chosen = Date.add(today, 21)
      chosen_string = Date.to_string(chosen)

      # Slots render as bare times ("9:00 AM") carrying no date, so the only
      # way to tell which day they were computed for is to make that day's
      # hours unique. An afternoon-only window on the requested day cannot be
      # confused with the 09:00 start every other day has.
      insert(:availability_override,
        schedule: schedule,
        date: chosen,
        override_type: "custom_hours",
        start_time: ~T[14:00:00],
        end_time: ~T[16:00:00]
      )

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat?timezone=#{timezone}&date=#{chosen_string}"
        )

      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      state = :sys.get_state(view.pid).socket.assigns

      assert state.selected_date == chosen_string
      assert state.available_slots != []

      # The requested day's window opens at 14:00 and closes at 16:00. A 9:00
      # slot could only have come from a fetch for a different day.
      assert "2:00 PM" in state.available_slots
      refute "9:00 AM" in state.available_slots
      refute "4:00 PM" in state.available_slots
    end

    # Rhythm's day button used to toggle: clicking the day already selected
    # cleared the selection. That was harmless while the step opened with
    # nothing selected, because the booker could only ever click an unselected
    # day. Auto-selection makes the highlighted day the single most likely
    # thing to be clicked, so the toggle turned the obvious first click into a
    # blanked time list — the day unhighlighted, the slots gone, and no way to
    # tell that from a day with no availability.
    #
    # Asserted through the rendered slot buttons rather than the assign: the
    # assign going nil is the mechanism, but what makes it a bug is that the
    # times vanish from the page.
    @tag :capture_log
    test "clicking the day the step opened on keeps it selected and keeps its times",
         %{conn: conn, profile: profile} do
      # "2" is Rhythm, whose day button carried the toggle.
      {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: "2"})

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      wait_until(fn -> has_element?(view, "button[data-testid='time-slot']") end)

      selected =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("button[data-testid='calendar-day'].selected")
        |> Floki.attribute("phx-value-date")
        |> List.first()

      assert selected, "expected the schedule step to open with a day selected"

      view
      |> element("button[data-testid='calendar-day'][phx-value-date='#{selected}']")
      |> render_click()

      html = render(view)
      document = Floki.parse_document!(html)

      assert document
             |> Floki.find("button[data-testid='calendar-day'].selected")
             |> Floki.attribute("phx-value-date") == [selected],
             "clicking the selected day deselected it"

      assert Floki.find(document, "button[data-testid='time-slot']") != [],
             "the times disappeared after clicking the selected day"
    end
  end

  describe "first_available_date/1 boundaries" do
    test "ignores days the map marks available but the grid draws as past" do
      today = Date.utc_today()
      yesterday = today |> Date.add(-1) |> Date.to_string()
      tomorrow = today |> Date.add(1) |> Date.to_string()

      # A stale map can carry a past day as available — the fetch covers a
      # 42-day display range that begins before today. The grid disables
      # those days unconditionally, so selecting one would load slots for a
      # square the booker cannot click.
      socket = socket_with(%{yesterday => true, tomorrow => true})

      assert NextAvailable.first_available_date(socket) == tomorrow
    end

    test "returns the earliest available day, not merely the first in map order" do
      today = Date.utc_today()
      near = today |> Date.add(2) |> Date.to_string()
      far = today |> Date.add(20) |> Date.to_string()

      assert NextAvailable.first_available_date(socket_with(%{far => true, near => true})) == near
    end

    test "returns nil when every day in the map is taken" do
      today = Date.utc_today()

      map =
        1..10
        |> Enum.map(&{today |> Date.add(&1) |> Date.to_string(), false})
        |> Map.new()

      assert NextAvailable.first_available_date(socket_with(map)) == nil
    end

    test "returns nil when availability has not been loaded" do
      assert NextAvailable.first_available_date(socket_with(nil)) == nil
      assert NextAvailable.first_available_date(socket_with(:loading)) == nil
    end
  end

  describe "apply/1" do
    test "leaves an existing selection alone and asks for no refetch" do
      socket = socket_with(%{}, selected_date: "2099-01-01")

      assert {returned, :done} = NextAvailable.apply(socket)
      assert returned.assigns.selected_date == "2099-01-01"
    end

    test "does not touch a reschedule in progress" do
      socket = socket_with(%{}, is_rescheduling: true)

      assert {returned, :done} = NextAvailable.apply(socket)
      assert returned.assigns.selected_date == nil
    end

    test "stops searching once the hop budget is spent" do
      # Standing in for a host whose calendar is empty for months: the
      # search must give up rather than chain fetches across the whole
      # advance-booking window on a single page load.
      socket = socket_with(%{}, auto_select_months_searched: 3)

      assert {_socket, :done} = NextAvailable.apply(socket)
    end

    test "asks for a refetch of the following month when the loaded range is dead" do
      today = Date.utc_today()
      socket = socket_with(%{(today |> Date.add(1) |> Date.to_string()) => false})

      assert {moved, :refetch} = NextAvailable.apply(socket)

      # The window advanced by exactly one month, and the map was cleared so
      # the stale one cannot be mistaken for the new month's answer.
      assert {moved.assigns.current_year, moved.assigns.current_month} !=
               {socket.assigns.current_year, socket.assigns.current_month}

      assert moved.assigns.month_availability_map == nil
      assert moved.assigns.auto_select_months_searched == 1
    end

    test "does not advance past the host's advance-booking window" do
      # A host whose window closes with the current month has no next month to
      # search; the forward arrow is disabled there and this must match it.
      #
      # The window is measured from today to the last day of this month rather
      # than pinned to a literal: a fixed small number stops bounding anything
      # once today is within that many days of the month end, and the test then
      # passes or fails on the calendar date it happens to run on.
      today = Date.utc_today()
      days_left_in_month = Date.days_in_month(today) - today.day
      socket = socket_with(%{}, advance_booking_days: days_left_in_month)

      assert {_socket, :done} = NextAvailable.apply(socket)
    end
  end

  defp next_step_disabled?(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("button[data-testid='next-step'][disabled]")
    |> Enum.any?()
  end

  defp socket_with(availability_map, overrides \\ []) do
    today = Date.utc_today()

    assigns =
      %{
        __changed__: %{},
        current_state: :schedule,
        selected_date: Keyword.get(overrides, :selected_date, nil),
        selected_time: nil,
        is_rescheduling: Keyword.get(overrides, :is_rescheduling, false),
        month_availability_map: availability_map,
        current_year: today.year,
        current_month: today.month,
        current_week_start: Date.beginning_of_week(today, :monday),
        user_timezone: "Etc/UTC",
        booking_window_days: Keyword.get(overrides, :advance_booking_days, 90),
        organizer_user_id: 1,
        auto_select_months_searched: Keyword.get(overrides, :auto_select_months_searched, 0),
        loading_slots: false,
        calendar_error: nil
      }

    %Socket{assigns: assigns}
  end
end
