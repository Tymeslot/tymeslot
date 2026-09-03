defmodule TymeslotWeb.Live.Scheduling.SlotHourToggleTest do
  @moduledoc """
  Pins the `expanded_hour` state machine behind the two-tier slot picker.

  A meeting type offering starts on a grid finer than its own duration turns a
  working day into a hundred-odd slots, so the booker opens one hour at a time.
  Which hour is open is parent state, not component state, and it has three
  values rather than two: `nil` (untouched, so the earliest hour shows),
  an integer, and `:none` (deliberately collapsed).

  The rendering that will drive this arrives with the theme work; these tests
  drive the event the themes forward, so the state transitions are pinned
  before any markup depends on them. The non-numeric case matters most: `hour`
  comes off a `phx-value-hour` attribute, which a visitor controls.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "hourtoggle",
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

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    # 15-minute starts on a 60-minute meeting: the grid is finer than the
    # meeting, which is the only shape that produces the two-tier picker.
    insert(:meeting_type,
      user: user,
      duration_minutes: 60,
      slot_interval_minutes: 15,
      name: "Deep Work",
      is_active: true
    )

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile}
  end

  describe "toggle_hour" do
    @tag :capture_log
    test "expands the requested hour", %{conn: conn, profile: profile} do
      %{view: view} = reach_loaded_slots(conn, profile)

      assert assigns(view).expanded_hour == nil
      assert assigns(view).slot_interval_minutes == 15
      assert assigns(view).duration_minutes == 60

      # An hour other than the one already effective, so the assignment is
      # visible rather than being swallowed by the collapse branch.
      other_hour = List.last(slot_hours(view))
      refute other_hour == earliest_slot_hour(view)

      toggle_hour(view, Integer.to_string(other_hour))

      assert assigns(view).expanded_hour == other_hour
    end

    @tag :capture_log
    test "collapses to :none when the currently effective hour is toggled",
         %{conn: conn, profile: profile} do
      %{view: view} = reach_loaded_slots(conn, profile)

      # Untouched state shows the earliest hour, so toggling *that* hour is the
      # booker closing what is open, even though no integer was ever stored.
      assert assigns(view).expanded_hour == nil
      earliest = earliest_slot_hour(view)

      toggle_hour(view, Integer.to_string(earliest))

      assert assigns(view).expanded_hour == :none

      # And it stays closed: a re-render must not spring it back open. The
      # explicit render/1 is the point of this assertion — without it the
      # second check merely re-reads the same state and pins nothing.
      _html = render(view)

      assert assigns(view).expanded_hour == :none

      # Choosing again reopens.
      toggle_hour(view, Integer.to_string(earliest))
      assert assigns(view).expanded_hour == earliest
    end

    @tag :capture_log
    test "a non-binary hour leaves the state untouched and the view alive",
         %{conn: conn, profile: profile} do
      %{view: view} = reach_loaded_slots(conn, profile)

      toggle_hour(view, "11")
      assert assigns(view).expanded_hour == 11

      # The non-numeric *string* case above is handled by `Integer.parse/1`
      # returning `:error`. A non-binary never reaches that call at all:
      # `Integer.parse/1` requires a bitstring and raises `FunctionClauseError`
      # otherwise. LiveView passes a non-"form" event payload through to
      # `handle_event/3` verbatim from client JSON, so a crafted socket push
      # can put any of these in `phx-value-hour` on the public booking page.
      for payload <- [11, 11.5, ~c"11", %{"hour" => 11}, ["11"], nil, true] do
        toggle_hour(view, payload)

        assert Process.alive?(view.pid),
               "a #{inspect(payload)} payload took the LiveView down"

        assert assigns(view).expanded_hour == 11
      end

      assert render(view) =~ "time-slot-button"
    end

    test "a non-binary navigate_to_step leaves the flow untouched and the view alive",
         %{conn: conn, profile: profile} do
      %{view: view} = reach_loaded_slots(conn, profile)

      state_before = assigns(view).current_state

      # Same guard, same reason: `navigate_to_step` parses its payload with
      # `Integer.parse/1` too, and it is reachable from the same public page.
      for payload <- [1, %{"step" => 1}, nil] do
        render_hook(view, "navigate_to_step", %{"step" => payload})

        assert Process.alive?(view.pid),
               "a #{inspect(payload)} step payload took the LiveView down"

        assert assigns(view).current_state == state_before
      end
    end

    test "a non-numeric hour leaves the state untouched and the view alive",
         %{conn: conn, profile: profile} do
      %{view: view} = reach_loaded_slots(conn, profile)

      toggle_hour(view, "11")
      assert assigns(view).expanded_hour == 11

      # `phx-value-hour` is visitor-controlled; `String.to_integer/1` would
      # raise here and take the LiveView down with it.
      toggle_hour(view, "not-an-hour")

      assert Process.alive?(view.pid)
      assert assigns(view).expanded_hour == 11
      assert render(view) =~ "time-slot-button"
    end

    @tag :capture_log
    test "reloading the slots collapses any expanded hour",
         %{conn: conn, profile: profile} do
      %{view: view, date: date} = reach_loaded_slots(conn, profile)

      toggle_hour(view, "11")
      assert assigns(view).expanded_hour == 11

      # Re-selecting the date funnels through a slot reload, which must reset
      # the expansion: the open hour describes a grid that no longer exists.
      view |> element("button.calendar-day[phx-value-date='#{date}']") |> render_click()
      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      assert assigns(view).expanded_hour == nil
    end
  end

  describe "a same-date refetch (timezone change, lost-slot retry)" do
    @tag :capture_log
    test "a deliberate :none survives it", %{conn: conn, profile: profile} do
      %{view: view, date: date} = reach_loaded_slots(conn, profile)

      earliest = earliest_slot_hour(view)
      toggle_hour(view, Integer.to_string(earliest))
      assert assigns(view).expanded_hour == :none

      # `{:fetch_available_slots, ...}` for the *same* date is exactly what a
      # timezone change or a lost-slot retry sends — it must not reopen a
      # deliberately collapsed hour.
      refetch_same_date(view, date)

      assert assigns(view).expanded_hour == :none
    end

    @tag :capture_log
    test "a stored integer hour survives it", %{conn: conn, profile: profile} do
      %{view: view, date: date} = reach_loaded_slots(conn, profile)

      other_hour = List.last(slot_hours(view))
      refute other_hour == earliest_slot_hour(view)

      toggle_hour(view, Integer.to_string(other_hour))
      assert assigns(view).expanded_hour == other_hour

      refetch_same_date(view, date)

      assert assigns(view).expanded_hour == other_hour
    end
  end

  defp reach_loaded_slots(conn, profile) do
    timezone = profile.timezone
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target = Date.add(today, 1)

    if target.month != today.month do
      view |> element("button[phx-click='next_month']") |> render_click()
    end

    date = Date.to_string(target)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    %{view: view, date: date}
  end

  # Read the offered slots off the page rather than from the grouping code, so
  # the expected hour is derived independently of the code under test. A theme
  # rendering the two-tier picker shows only the open hour's minutes, so the
  # hour buttons are as much a source of offered hours as the minutes are.
  defp slot_hours(view) do
    document = view |> render() |> Floki.parse_document!()

    from_minutes =
      document
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> Enum.map(&TimeSlots.parse_time_slot(&1).hour)

    from_hours =
      document
      |> Floki.attribute("[data-testid='slot-hour']", "phx-value-hour")
      |> Enum.map(&String.to_integer/1)

    hours =
      (from_minutes ++ from_hours)
      |> Enum.uniq()
      |> Enum.sort()

    assert length(hours) > 1,
           "expected the day to offer slots in more than one hour, got: #{inspect(hours)}"

    hours
  end

  defp earliest_slot_hour(view), do: view |> slot_hours() |> List.first()

  defp toggle_hour(view, hour) do
    send(view.pid, {:step_event, :schedule, :toggle_hour, hour})
    render(view)
  end

  # `:fetch_available_slots` for the date already selected is the message
  # both a timezone change and a lost-slot retry send — the production
  # message itself, not a proxy for it.
  defp refetch_same_date(view, date) do
    duration = assigns(view).duration_minutes
    timezone = assigns(view).user_timezone

    send(view.pid, {:fetch_available_slots, date, duration, timezone})
    render(view)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
