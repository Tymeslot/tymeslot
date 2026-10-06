defmodule TymeslotWeb.Live.Scheduling.TimezoneChangeAvailabilityTest do
  @moduledoc """
  Changing "Your timezone" on the schedule step recomputes which days are
  bookable, not just the selected day's times.

  The host keeps Monday evenings in London, 22:00 to 02:00 the next morning.
  Read from Kyiv, two hours ahead, that whole window falls on Tuesday, so every
  Monday is greyed out. Read from London, Monday offers 22:00 and 23:00. A
  booker who opens the page in Kyiv and switches to London must see Mondays
  come alive; before the fix the grid kept the map computed for Kyiv and only
  the slot list followed the new zone.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  @host_zone "Europe/London"
  @booker_zone "Europe/Kyiv"

  @calendar_day "button[data-testid='calendar-day']"
  @time_slot "button[data-testid='time-slot']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  for {theme_id, theme_name} <- [{"1", "Quill"}, {"2", "Rhythm"}] do
    @tag :capture_log
    test "#{theme_name}: the bookable days follow the new timezone", %{conn: conn} do
      profile = overnight_monday_host(unquote(theme_id))

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@booker_zone}")

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      monday = next_monday()
      tuesday = Date.add(monday, 1)

      BookingTestHelpers.advance_calendar_to(view, monday)

      # In Kyiv the window is Tuesday 00:00 to 04:00, and Monday has nothing.
      wait_until(fn -> bookable?(view, tuesday) end)
      refute bookable?(view, monday)

      view |> element(day(tuesday)) |> render_click()
      wait_until(fn -> slot_times(view) != [] end)
      assert slot_times(view) == ["12:00 AM", "1:00 AM", "2:00 AM", "3:00 AM"]

      change_timezone(view, @host_zone)

      # In London the same window is Monday 22:00 to Tuesday 02:00: Monday
      # becomes bookable, and Tuesday keeps only the tail of the window.
      wait_until(fn -> bookable?(view, monday) end)
      assert bookable?(view, tuesday)

      # The selected day stays selected and its times are re-read in London.
      wait_until(fn -> slot_times(view) == ["12:00 AM", "1:00 AM"] end)

      view |> element(day(monday)) |> render_click()
      wait_until(fn -> slot_times(view) == ["10:00 PM", "11:00 PM"] end)
    end
  end

  defp overnight_monday_host(theme_id) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "night-owl-#{theme_id}",
        booking_theme: theme_id,
        timezone: @host_zone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: 1,
      is_available: true,
      start_time: ~T[22:00:00],
      end_time: ~T[02:00:00],
      ends_next_day: true
    )

    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, duration_minutes: 60, is_active: true)
    profile
  end

  # A Monday at least two days out in both zones, so neither today's cut-off
  # nor the zones disagreeing about today can touch it.
  defp next_monday do
    from = @booker_zone |> DateTime.now!() |> DateTime.to_date() |> Date.add(2)
    Date.add(from, rem(8 - Date.day_of_week(from), 7))
  end

  defp day(date), do: "#{@calendar_day}[phx-value-date='#{Date.to_string(date)}']"

  defp bookable?(view, date), do: has_element?(view, "#{day(date)}:not([disabled])")

  # Through the picker the booker uses: open it, search for the city, pick it.
  defp change_timezone(view, zone) do
    view |> element("[phx-click='toggle_timezone_dropdown']") |> render_click()
    view |> element("input.timezone-search") |> render_keyup(%{"search" => "London"})

    view
    |> element("button.timezone-option[phx-value-timezone='#{zone}']")
    |> render_click()
  end

  defp slot_times(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(@time_slot, "phx-value-time")
  end
end
