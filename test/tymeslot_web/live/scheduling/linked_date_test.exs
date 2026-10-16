defmodule TymeslotWeb.Live.Scheduling.LinkedDateTest do
  @moduledoc """
  Pins what a booking link naming a day (`?date=YYYY-MM-DD`) opens on.

  A day inside the booking window opens the calendar on that day's month and
  week, selected, with that month's availability fetched. Before, the calendar
  always opened on today's month, so a link to a later month showed a
  selection nowhere on the calendar. A day outside the window (already past,
  or beyond the last bookable day) is dropped, and the booker lands on the
  first free day, as if the link had named none.
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

  @zone "Europe/Tallinn"
  @window_days 90

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
        username: "linked-date-#{System.unique_integer([:positive])}",
        booking_theme: "1",
        timezone: @zone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: @window_days,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
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

  for theme <- ThemeTestMatrix.all() do
    @theme theme

    # A dead render of the calendar's day buttons. A week grid draws no days
    # until it asks for its week, so a week-grid theme's linked day is
    # covered by its own journey test.
    if theme.schedule_view == :calendar do
      test "#{theme.slug} opens a link to a later month on that day's month and week",
           %{conn: conn, profile: profile} do
        {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: @theme.id})
        # Sunday 31 January 2027 in Tallinn; the linked day is Wednesday 10 March.
        freeze_clock(~U[2027-01-31 12:00:00Z])

        document =
          conn
          |> get("/#{profile.username}/30-minutes?timezone=#{@zone}&date=2027-03-10")
          |> html_response(200)
          |> Floki.parse_document!()

        # Every day button in both themes: Quill's month grid and narrow-screen
        # week row, Rhythm's week strip.
        days = Floki.find(document, "button[phx-click='select_date'][phx-value-date]")

        selected =
          days
          |> Enum.filter(&selected_day?/1)
          |> Floki.attribute("phx-value-date")
          |> Enum.uniq()

        assert selected == ["2027-03-10"],
               "expected the linked day to be drawn selected, found #{inspect(selected)}"

        # A week strip still on today's week would draw 25 to 31 January.
        stale_week = Enum.map(0..6, &Date.to_iso8601(Date.add(~D[2027-01-25], &1)))
        drawn = Floki.attribute(days, "phx-value-date")

        assert Enum.filter(drawn, &(&1 in stale_week)) == [],
               "expected no day of today's week on a calendar opened on 10 March"
      end
    end

    test "#{theme.slug} fetches the linked month's availability once connected",
         %{conn: conn, profile: profile, meeting_type: meeting_type} do
      {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: @theme.id})
      # The 15th of next month: always another month, and inside the window.
      next_month = Date.shift(today(), month: 1)
      linked = Date.new!(next_month.year, next_month.month, 15)

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"timezone" => @zone})
        |> live("/#{profile.username}/30-minutes?timezone=#{@zone}&date=#{linked}")

      assert %{
               selected_date: selected_date,
               current_year: year,
               current_month: month,
               current_week_start: week_start
             } = live_assigns(view)

      assert selected_date == Date.to_iso8601(linked)
      assert {year, month} == {linked.year, linked.month}
      assert week_start == Date.beginning_of_week(linked, :monday)

      wait_until(fn -> month_cached?(view, profile, meeting_type) end)
    end

    for {case_name, offset} <- [
          {"already past", -2},
          {"beyond the booking window", @window_days + 2}
        ] do
      @offset offset

      test "#{theme.slug} drops a linked day #{case_name} and lands on the first free day",
           %{conn: conn, profile: profile} do
        {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: @theme.id})
        today = today()
        linked = Date.to_iso8601(Date.add(today, @offset))

        {:ok, view, _html} =
          conn
          |> put_connect_params(%{"timezone" => @zone})
          |> live("/#{profile.username}/30-minutes?timezone=#{@zone}&date=#{linked}")

        wait_until(fn -> live_assigns(view).auto_select_settled == true end)

        %{selected_date: landed} = live_assigns(view)

        assert landed != linked, "the out-of-range linked day #{linked} is still selected"
        assert {:ok, landed_date} = Date.from_iso8601(landed)
        assert Date.compare(landed_date, today) != :lt
        assert Date.compare(landed_date, Date.add(today, @window_days)) != :gt
      end
    end
  end

  defp selected_day?(button) do
    classes = button |> Floki.attribute("class") |> List.first("") |> String.split()
    "selected" in classes or "calendar-day--selected" in classes
  end

  defp today, do: @zone |> DateTime.now!() |> DateTime.to_date()

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Whether the month on screen has been fetched for the visitor's timezone.
  # Availability is cached per display range and timezone, and a failed
  # computation is never cached, so this probe cannot add an entry of its own.
  defp month_cached?(view, profile, meeting_type) do
    %{current_year: year, current_month: month, week_start: week_start} = live_assigns(view)
    {start_date, end_date} = Calculate.display_range(year, month, week_start)

    key =
      AvailabilityCache.availability_range_key(
        profile.user_id,
        start_date,
        end_date,
        @zone,
        meeting_type.duration_minutes,
        meeting_type.id
      )

    match?({:ok, _map}, AvailabilityCache.get_or_compute_events(key, fn -> {:error, :probe} end))
  end
end
