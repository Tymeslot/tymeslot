defmodule TymeslotWeb.Live.Themes.ScrollLocaleSwitchTest do
  @moduledoc """
  A language switch on Fixture Scroll (`"96"`), a `Continuous` journey whose
  language switcher shows on every moment. The switch is a full redirect, so
  the page that comes back knows only what the URL carries: the meeting type,
  the day and the time ride along, and the page lands where the visitor was,
  on the route the visit started on, so a type chosen on the overview stays
  revisitable and a direct or private link's stays locked.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :i18n
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestHelpers.Eventually
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType

  @theme_id "96"

  @types [
    [name: "Quick Chat", duration_minutes: 30],
    [name: "Long Chat", duration_minutes: 60]
  ]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp state(view, moment), do: first_value(view, "##{moment}-step", "data-moment-state")

  # Chooses the type and the first free time a few days ahead, so neither a
  # slot boundary nor the minimum notice can take the time between the pick
  # and the remount. Returns the day and time.
  defp choose(view, slug) do
    BookingDriver.choose_meeting_type(view, slug)
    day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
    {^day, _time} = BookingDriver.pick_first_slot(view, on: day)
    Map.take(live_assigns(view), [:selected_date, :selected_time])
  end

  # Drives the real switcher and follows its external redirect; returns the
  # path it redirected to and the page mounted there.
  defp switch_language(view, conn, locale, connect_params \\ %{}) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    {:ok, conn} =
      view
      |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
      |> render_click()
      |> follow_redirect(conn)

    {:ok, view, _html} = conn |> put_connect_params(connect_params) |> live()
    {conn.request_path, view}
  end

  defp await_moment(view, moment, wanted) do
    Eventually.eventually(fn -> state(view, moment) == wanted end, timeout: 5000)
  end

  describe "a switch after choosing on the overview" do
    test "keeps the meeting type, the day and the time, and lands on the details",
         %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-overview", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      chosen = choose(view, "quick-chat")
      {path, view} = switch_language(view, conn, "de")

      assert path == "/#{profile.username}"
      assert has_element?(view, "[data-locale='de']")
      await_moment(view, :you, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "quick-chat"
      assert Map.take(assigns, [:selected_date, :selected_time]) == chosen
      assert state(view, :offer) == "done"
      assert state(view, :when) == "done"

      # Came through the overview, so the meeting type may still be changed.
      assert assigns.entered_via_overview
      assert MeetingType.revisitable?(assigns)
    end

    @tag :capture_log
    test "drops a time that was taken meanwhile and keeps the day", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-taken", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      chosen = choose(view, "quick-chat")

      # Someone else books that very time first.
      {:ok, other, _html} = live(build_conn(), ~p"/#{profile.username}")

      BookingDriver.book(other,
        meeting_type: "quick-chat",
        date: chosen.selected_date,
        time: chosen.selected_time,
        attendee: %{name: "Grace Hopper", email: "grace@example.com"}
      )

      assert Repo.get_by(MeetingSchema, attendee_email: "grace@example.com")
      AvailabilityCache.clear_all()

      {_path, view} = switch_language(view, conn, "de")
      await_moment(view, :when, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "quick-chat"
      assert assigns.selected_date == chosen.selected_date
      assert assigns.selected_time == nil
      refute has_element?(view, "#you-step")
    end
  end

  describe "a carried time that cannot be checked" do
    @tag :capture_log
    test "is dropped when its day's times fail to load", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-unchecked", types: @types)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :all_calendars_unavailable}
      end)

      day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}/quick-chat?date=#{day}&time=2:00%20PM&locale=de")

      Eventually.eventually(fn -> live_assigns(view)[:calendar_error] != nil end)
      await_moment(view, :when, "current")

      assert live_assigns(view).selected_time == nil
      refute has_element?(view, "#you-step")
    end
  end

  describe "a switch after choosing a timezone" do
    test "keeps the timezone chosen over the browser's, and the time in it", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-zone", types: @types)
      browser = %{"timezone" => "Europe/Warsaw"}
      {:ok, view, _html} = conn |> put_connect_params(browser) |> live(~p"/#{profile.username}")

      BookingDriver.choose_meeting_type(view, "quick-chat")
      send(view.pid, {:step_event, :when, :change_timezone, "America/New_York"})
      Eventually.eventually(fn -> live_assigns(view).user_timezone == "America/New_York" end)

      day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
      {^day, time} = BookingDriver.pick_first_slot(view, on: day)

      {_path, view} = switch_language(view, conn, "de", browser)
      await_moment(view, :you, "current")

      assigns = live_assigns(view)
      assert assigns.user_timezone == "America/New_York"

      assert Map.take(assigns, [:selected_date, :selected_time]) == %{
               selected_date: day,
               selected_time: time
             }
    end
  end

  describe "a switch on a meeting type's own link" do
    test "keeps the day and the time, and the type stays locked", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-direct", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/long-chat")

      chosen = choose(view, "long-chat")
      {path, view} = switch_language(view, conn, "de")

      assert path == "/#{profile.username}/long-chat"
      await_moment(view, :you, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "long-chat"
      assert Map.take(assigns, [:selected_date, :selected_time]) == chosen
      refute assigns.entered_via_overview
      refute MeetingType.revisitable?(assigns)
    end
  end

  describe "a private meeting type" do
    setup do
      %{profile: profile, meeting_types: [_public, private]} =
        seed_organiser(@theme_id, "scroll-locale-private",
          types: [[name: "Quick Chat", duration_minutes: 30], [name: "Secret", is_private: true]]
        )

      %{profile: profile, slug: MeetingTypes.effective_slug(private)}
    end

    test "is not chosen by naming it on the overview", %{conn: conn, profile: profile, slug: slug} do
      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}?duration=#{slug}&entered_via_overview=true&locale=de")

      assert state(view, :offer) == "current"
      refute has_element?(view, "#when-step")
      refute has_element?(view, "[data-fact='meeting_type'][data-value='#{slug}']")
    end

    test "stays locked on its own link whatever the URL claims",
         %{conn: conn, profile: profile, slug: slug} do
      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}/#{slug}?entered_via_overview=true&via=overview")

      assigns = live_assigns(view)
      assert assigns.meeting_type.is_private
      refute assigns.entered_via_overview
      refute MeetingType.revisitable?(assigns)
    end
  end
end
