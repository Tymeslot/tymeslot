defmodule TymeslotWeb.Live.Scheduling.VisitorTodayTest do
  @moduledoc """
  Pins the booking calendar opening on today as the visitor's clock has it,
  not as the server's UTC clock has it.

  Around midnight UTC the two disagree for much of the world: at midday UTC it
  is already tomorrow in Kiritimati (UTC+14), and at 05:00 UTC it is still
  yesterday in Pago Pago (UTC-11). The page's first render runs in the test
  process, so `Tymeslot.Clock` can be frozen at such an instant for it. The
  connected LiveView runs in a process of its own where it cannot, so those
  tests pick whichever of the two zones is on another date than UTC when they
  run; at every instant one of them is.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

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
        username: "visitor-today-#{System.unique_integer([:positive])}",
        booking_theme: "1",
        timezone: "Europe/Tallinn"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 90,
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

    meeting_type =
      insert(:meeting_type, user: user, name: "30 Minutes", duration_minutes: 30, is_active: true)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, meeting_type: meeting_type}
  end

  # Today's mark on the calendar's day buttons, in a dead render; a week grid draws no days until it asks for its week.
  for theme <- ThemeTestMatrix.all(),
      theme.schedule_view == :calendar,
      {zone, frozen_at, local_today} <- [
        {"Pacific/Kiritimati", ~U[2027-01-31 12:00:00Z], ~D[2027-02-01]},
        {"Pacific/Pago_Pago", ~U[2027-02-01 05:00:00Z], ~D[2027-01-31]}
      ] do
    @theme theme
    @zone zone
    @frozen_at frozen_at
    @local_today local_today

    test "#{theme.slug} opens the calendar on today in #{zone}, not in UTC",
         %{conn: conn, profile: profile} do
      {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: @theme.id})
      freeze_clock(@frozen_at)

      html =
        conn
        |> get("/#{profile.username}/30-minutes?timezone=#{@zone}")
        |> html_response(200)

      # Quill draws today twice (month grid and narrow-screen week row), so
      # compare the distinct dates marked as today.
      todays =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='calendar-day'][aria-current='date']")
        |> Floki.attribute("data-date")
        |> Enum.uniq()

      assert todays == [Date.to_iso8601(@local_today)],
             "expected the calendar to show #{@local_today} as today in #{@zone}, " <>
               "found #{inspect(todays)}"
    end
  end

  test "the connected page opens on today in the timezone the browser reports",
       %{conn: conn, profile: profile} do
    now = DateTime.utc_now()

    zone =
      Enum.find(
        ["Pacific/Kiritimati", "Pacific/Pago_Pago"],
        &(local_date(now, &1) != DateTime.to_date(now))
      )

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"timezone" => zone})
      |> live("/#{profile.username}")

    today = local_date(DateTime.utc_now(), zone)

    assert %{
             user_timezone: ^zone,
             calendar_today: ^today,
             current_year: year,
             current_month: month,
             current_week_start: week_start
           } = live_assigns(view)

    assert {year, month} == {today.year, today.month}
    assert week_start == Date.beginning_of_week(today, :monday)
  end

  test "picking another timezone refetches the month's availability for that zone's days",
       %{conn: conn, profile: profile, meeting_type: meeting_type} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"timezone" => "Europe/Tallinn"})
      |> live("/#{profile.username}/30-minutes")

    wait_until(fn -> live_assigns(view).availability_status == :loaded end)
    refute month_cached?(view, profile, meeting_type, "Pacific/Kiritimati")

    # The message the schedule step's timezone picker sends when a zone is picked.
    send(view.pid, {:step_event, :schedule, :change_timezone, "Pacific/Kiritimati"})

    wait_until(fn -> month_cached?(view, profile, meeting_type, "Pacific/Kiritimati") end)
    assert live_assigns(view).user_timezone == "Pacific/Kiritimati"
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp local_date(utc_now, zone), do: utc_now |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  # Whether the month on screen has been fetched for `timezone`. Availability
  # is cached per display range and timezone, and a failed computation is never
  # cached, so this probe cannot add an entry of its own.
  defp month_cached?(view, profile, meeting_type, timezone) do
    %{current_year: year, current_month: month} = live_assigns(view)
    {start_date, end_date} = Calculate.display_range(year, month)

    key =
      AvailabilityCache.availability_range_key(
        profile.user_id,
        start_date,
        end_date,
        timezone,
        meeting_type.duration_minutes,
        meeting_type.id
      )

    match?({:ok, _map}, AvailabilityCache.get_or_compute_events(key, fn -> {:error, :probe} end))
  end
end
