defmodule TymeslotWeb.Live.Themes.AvailabilityRefinementTest do
  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    Sandbox.mode(Repo, {:shared, self()})
    ensure_rate_limiter_started()
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

  describe "Quill theme availability refinement" do
    test "refines availability based on calendar conflicts", %{conn: conn} do
      timezone = "America/New_York"
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "refinement-test-#{System.unique_integer([:positive])}",
          booking_theme: "1",
          timezone: timezone,
          advance_booking_days: 30,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      _meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Refinement Chat",
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

      today = Date.utc_today()
      # Pick a date 5 days from today to be safe and avoid navigation issues
      target_date = Date.add(today, 5)
      date_str = Date.to_string(target_date)

      # Use a unique duration to ensure cache isolation
      _unique_duration = 30
      slug = "refinement-chat"

      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok,
         [
           %{
             uid: "busy-day-#{System.unique_integer()}",
             start_time: DateTime.new!(target_date, ~T[00:00:00], timezone),
             end_time: DateTime.new!(target_date, ~T[23:59:59], timezone)
           }
         ]}
      end)

      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}/#{slug}?timezone=#{timezone}")

      # If target_date is in the next month, we might need to navigate
      if target_date.month != today.month do
        view |> element("button[phx-click='next_month']") |> render_click()
      end

      wait_until(fn ->
        html = render(view)

        # Check for both the date string and the disabled attribute on that specific date button
        (html =~ "data-date=\"#{date_str}\"" or html =~ "phx-value-date=\"#{date_str}\"") and
          has_element?(
            view,
            "button[data-testid='calendar-day'][phx-value-date='#{date_str}'][disabled]"
          )
      end)
    end

    test "greys out today if business hours have passed", %{conn: conn} do
      # 14 hours ahead of UTC
      timezone = "Etc/GMT-14"
      user = insert(:user)
      username = "today-grey-test-#{System.unique_integer([:positive])}"

      profile =
        insert(:profile,
          user: user,
          booking_theme: "1",
          timezone: timezone,
          username: username
        )

      # Set business hours that have definitely passed for today in this timezone
      # by picking a very early window (00:00 - 01:00)
      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[00:00:00],
          end_time: ~T[01:00:00]
        )
      end)

      _meeting_type =
        insert(:meeting_type,
          user: user,
          name: "30 Minutes",
          duration_minutes: 30,
          is_active: true
        )

      insert(:calendar_integration, user: user, is_active: true)

      now_in_tz = DateTime.shift_zone!(DateTime.utc_now(), timezone)
      today_in_tz = DateTime.to_date(now_in_tz)
      today_str = Date.to_string(today_in_tz)

      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}/30-minutes?timezone=#{timezone}")

      # Since business hours are 00:00-01:00 and we are in GMT-14,
      # today should be disabled as long as it's past 01:00 in that timezone.
      # However, with min_advance_hours (default 3), today should ALWAYS be disabled
      # in this specific setup, even at 00:00.

      wait_until(fn ->
        has_element?(
          view,
          "button[data-testid='calendar-day'][phx-value-date='#{today_str}'][disabled]"
        )
      end)
    end
  end

  defp ensure_rate_limiter_started do
    # RateLimit (Hammer ETS) is always started in the supervision tree.
    RateLimiter.clear_all()
  end
end
