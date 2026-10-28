defmodule TymeslotWeb.Live.Scheduling.RefusedCalendarTest do
  @moduledoc """
  A booking page whose organiser's calendar refused its credentials offers no
  times until the organiser reconnects it. A guest is told the page cannot
  show times, with no promise that retrying helps and no word of which
  calendar failed; the organiser, signed in or holding a preview token, is
  told which calendar it is and where to reconnect it. A calendar that is
  merely unreachable still tells the guest to try again shortly.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory

  @moduletag :scheduling
  @moduletag :calendar
  @moduletag :live

  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Live.Scheduling.PreviewToken
  alias TymeslotWeb.ThemeTestMatrix

  @calendar_name "Work iCloud"
  @notice "[data-testid='calendar-refused-notice']"
  @transient "Please try again in a few minutes."
  @disconnected "This booking page can&#39;t show times right now."

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    # Every read of the organiser's calendars fails, as a refused credential
    # makes it fail.
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :all_calendars_unavailable}
    end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      setup do
        account =
          BookingTestHelpers.seed_booking_account(
            unquote(theme.id),
            "refused#{unquote(theme.id)}",
            "America/New_York"
          )

        Repo.update_all(CalendarIntegrationSchema, set: [name: @calendar_name])
        account
      end

      @tag :capture_log
      test "a guest is told the page cannot show times, not to retry, when the calendar is refused",
           %{conn: conn, profile: profile} do
        flag_refused()
        html = open_day(conn, profile)

        assert html =~ @disconnected
        refute html =~ @transient
        refute html =~ @calendar_name
        refute has_element?(open_view(conn, profile), @notice)
      end

      @tag :capture_log
      test "a guest is told to try again when the calendar is merely unreachable",
           %{conn: conn, profile: profile} do
        html = open_day(conn, profile)

        assert html =~ @transient
        refute html =~ @disconnected
      end

      @tag :capture_log
      test "the signed-in organiser is told which calendar to reconnect, on arrival",
           %{conn: conn, profile: profile, user: user} do
        flag_refused()
        view = open_view(sign_in(conn, user), profile)

        assert view |> element(@notice) |> render() =~ @calendar_name

        assert has_element?(
                 view,
                 "#{@notice} a[href='/dashboard/integrations?tab=calendars']"
               )
      end

      @tag :capture_log
      test "the organiser previewing with a token is told too",
           %{conn: conn, profile: profile, user: user} do
        flag_refused()

        {:ok, view, _html} =
          live(
            conn,
            "/#{profile.username}?preview=true&preview_token=#{PreviewToken.sign(user.id)}"
          )

        assert view |> element(@notice) |> render() =~ @calendar_name
      end

      @tag :capture_log
      test "another signed-in user sees no notice",
           %{conn: conn, profile: profile} do
        flag_refused()
        view = open_view(sign_in(conn, insert(:user)), profile)

        refute has_element?(view, @notice)
      end

      @tag :capture_log
      test "the organiser sees no notice while every calendar is connected",
           %{conn: conn, profile: profile, user: user} do
        view = open_view(sign_in(conn, user), profile)

        refute has_element?(view, @notice)
      end
    end
  end

  defp sign_in(conn, user) do
    conn |> init_test_session(%{}) |> AuthTestHelpers.log_in_user(user)
  end

  defp flag_refused, do: Repo.update_all(CalendarIntegrationSchema, set: [needs_reauth: true])

  defp open_view(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")
    view
  end

  # Opens the page, takes the way to the schedule and picks tomorrow, then
  # returns the page once the day's fetch has failed.
  defp open_day(conn, profile) do
    view = open_view(conn, profile)
    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    BookingDriver.continue(view)

    tomorrow =
      profile.timezone
      |> DateTime.now!()
      |> DateTime.to_date()
      |> Date.add(1)
      |> Date.to_iso8601()

    BookingDriver.pick_date(view, tomorrow)
    wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:calendar_error] != nil end)
    render(view)
  end
end
