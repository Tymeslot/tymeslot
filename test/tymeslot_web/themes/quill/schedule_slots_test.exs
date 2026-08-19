defmodule TymeslotWeb.Themes.Quill.ScheduleSlotsTest do
  @moduledoc """
  Covers how Quill presents a day's slots.

  A meeting type offering starts on a grid finer than its own duration turns a
  working day into a hundred-odd buttons, so Quill nests them one level deeper:
  the booker sees an hour per button and opens one hour at a time. Every other
  meeting type keeps the flat grid it has always had, which is the case the
  last test pins.

  Expected times are read off the rendered attributes rather than written into
  the test, so an assertion cannot quietly stop matching what is offered.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Utils.DateTimeUtils.Display

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
        username: "quillslots",
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

    insert(:calendar_integration, user: user, is_active: true)

    %{user: user, profile: profile}
  end

  describe "a grid finer than the meeting" do
    setup %{user: user} do
      # 5-minute starts on a 30-minute meeting: the only shape that produces
      # the two-tier picker.
      insert(:meeting_type,
        user: user,
        name: "Rapid Fire",
        duration_minutes: 30,
        slot_interval_minutes: 5,
        is_active: true
      )

      :ok
    end

    @tag :capture_log
    test "offers hours rather than every minute of the day",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      assert length(hours) > 1

      open = List.first(hours)
      times = rendered_times(view)
      assert times != []

      assert Enum.all?(times, &(TimeSlots.parse_time_slot(&1).hour == open)),
             "expected only the open hour's minutes to render, got: #{inspect(times)}"

      # The same minute offset in a closed hour is certainly on offer, and must
      # not be on the page. Deriving it from a rendered time keeps the format
      # and the minute honest.
      closed = List.last(hours)
      refute has_element?(view, slot_selector(minute_of(times, closed)))
    end

    @tag :capture_log
    test "opens the earliest hour so real times are visible without a click",
         %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      earliest = List.first(rendered_hours(view))

      assert has_element?(
               view,
               "[data-testid='slot-hour'][phx-value-hour='#{earliest}'][aria-expanded='true']"
             )

      times = rendered_times(view)
      assert times != []
      assert Enum.all?(times, &(TimeSlots.parse_time_slot(&1).hour == earliest))
      assert has_element?(view, slot_selector(List.first(times)))
    end

    @tag :capture_log
    test "opening a later hour reveals its minutes", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      hours = rendered_hours(view)
      later = List.last(hours)
      refute later == List.first(hours)

      expected = minute_of(rendered_times(view), later)
      refute has_element?(view, slot_selector(expected))

      view |> element("[data-testid='slot-hour'][phx-value-hour='#{later}']") |> render_click()

      assert has_element?(view, slot_selector(expected))
      assert Enum.all?(rendered_times(view), &(TimeSlots.parse_time_slot(&1).hour == later))
    end

    @tag :capture_log
    test "selecting a minute records the choice", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      open = List.first(rendered_hours(view))
      chosen = view |> rendered_times() |> List.first()

      view |> element(slot_selector(chosen)) |> render_click()

      # Scoped to the open hour's panel, so the assertion only holds while the
      # minutes really are nested under their hour.
      assert has_element?(
               view,
               "#slot-hour-panel-#{open} " <>
                 "button.time-slot-button--selected[phx-value-time='#{chosen}']"
             )
    end
  end

  describe "a meeting type with no interval of its own" do
    setup %{user: user} do
      insert(:meeting_type,
        user: user,
        name: "Standard",
        duration_minutes: 30,
        slot_interval_minutes: nil,
        is_active: true
      )

      :ok
    end

    @tag :capture_log
    test "keeps the flat grid", %{conn: conn, profile: profile} do
      view = reach_loaded_slots(conn, profile)

      refute has_element?(view, "[data-testid='slot-hour']")

      times = rendered_times(view)
      assert times != []

      assert times |> Enum.map(&TimeSlots.parse_time_slot(&1).hour) |> Enum.uniq() |> length() > 1,
             "expected the flat grid to show every hour's slots at once"
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

    view
  end

  defp document(view), do: view |> render() |> Floki.parse_document!()

  defp rendered_hours(view) do
    view
    |> document()
    |> Floki.attribute("[data-testid='slot-hour']", "phx-value-hour")
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  # Hour buttons carry no `phx-value-time`, so this is exactly the minute slots.
  defp rendered_times(view) do
    view |> document() |> Floki.attribute("button.time-slot-button", "phx-value-time")
  end

  # The same minute as a slot already on the page, moved into `hour`.
  defp minute_of(times, hour) do
    times
    |> List.first()
    |> TimeSlots.parse_time_slot()
    |> Map.put(:hour, hour)
    |> Display.format_time_for_display()
  end

  defp slot_selector(time), do: "button.time-slot-button[phx-value-time='#{time}']"
end
