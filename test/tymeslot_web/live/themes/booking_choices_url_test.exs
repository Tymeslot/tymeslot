defmodule TymeslotWeb.Live.Themes.BookingChoicesUrlTest do
  @moduledoc """
  A booking page keeps its URL in step with the visitor's choices
  (`ChoicesInUrl`), so a socket that reconnects, which mounts the LiveView
  again from the URL in the address bar, lands where the visitor was: the
  same moment, with the same meeting type, length, day and time. Run on the
  classic themes, whose paged journey carries the moment on screen as
  `step`, and on Fixture Scroll (`"96"`), a page that moves on by itself.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestHelpers.Eventually
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @attendee %{name: "Ada Lovelace", email: "ada@example.com"}

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

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  # A reconnect: a fresh LiveView mounted from the URL in the address bar.
  defp remount(url) do
    {:ok, view, _html} = live(build_conn(), url)
    view
  end

  defp a_few_days_ahead, do: Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

  for {theme, theme_id} <- [quill: "1", rhythm: "2"] do
    describe "#{theme}, a paged journey" do
      @tag :capture_log
      test "a remount lands on the details with the type, length, day and time chosen",
           %{conn: conn} do
        %{profile: profile, user: user} =
          seed_organiser(unquote(theme_id), "url-paged-#{unquote(theme)}",
            types: [[name: "Quick Chat", duration_minutes: 30, extra_lengths_minutes: [60, 15]]]
          )

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.choose_meeting_type(view, "quick-chat")
        BookingDriver.continue(view)
        BookingDriver.choose_length(view, 15)
        BookingDriver.continue(view)
        {day, time} = BookingDriver.pick_first_slot(view, on: a_few_days_ahead())
        BookingDriver.continue(view)
        assert live_assigns(view).current_state == :booking

        url = BookingTestHelpers.last_patched_url(view)
        assert URI.parse(url).path == "/#{profile.username}"

        assert %{
                 "duration" => "quick-chat",
                 "minutes" => "15",
                 "date" => ^day,
                 "time" => ^time,
                 "step" => "booking"
               } = query(url)

        view = remount(url)
        assigns = live_assigns(view)

        assert assigns.current_state == :booking
        assert assigns.selected_duration == "quick-chat"
        assert assigns.chosen_length_minutes == 15
        assert {assigns.selected_date, assigns.selected_time} == {day, time}
        # The route is still the one the visit started on.
        assert assigns.entered_via_overview

        BookingDriver.submit(view, @attendee)
        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.duration == 15
      end

      # A patch runs `handle_params/3` again; the page's own must not enter
      # the moment again, which would issue a fresh submission token and
      # start the details over.
      test "the page's own patch leaves the moment on screen as it is", %{conn: conn} do
        %{profile: profile} = seed_organiser(unquote(theme_id), "url-own-#{unquote(theme)}")
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.book(view, meeting_type: "quick-chat", until: :attendee)
        token = live_assigns(view).submission_token
        assert token not in [nil, ""]

        send(view.pid, {:step_event, :booking, :change_timezone, "America/New_York"})
        Eventually.eventually(fn -> live_assigns(view).user_timezone == "America/New_York" end)

        assert query(BookingTestHelpers.last_patched_url(view))["visitor_timezone"] ==
                 "America/New_York"

        assert live_assigns(view).current_state == :booking
        assert live_assigns(view).submission_token == token
      end

      test "a booking made leaves no choice in the URL", %{conn: conn} do
        %{profile: profile} = seed_organiser(unquote(theme_id), "url-booked-#{unquote(theme)}")
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.book(view, meeting_type: "quick-chat", until: :attendee)
        assert query(BookingTestHelpers.last_patched_url(view))["step"] == "booking"

        BookingDriver.submit(view, @attendee)
        assert live_assigns(view).current_state == :confirmation

        url = BookingTestHelpers.last_patched_url(view)
        assert URI.parse(url).path == "/#{profile.username}"
        assert URI.parse(url).query in [nil, ""]
      end
    end
  end

  describe "a meeting type's own link" do
    # A direct link never shows the organiser's other types, so a URL naming
    # the overview resumes no further back than the calendar.
    test "never resumes on the overview", %{conn: conn} do
      %{profile: profile} = seed_organiser("1", "url-direct")
      {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?step=overview")

      assigns = live_assigns(view)
      assert assigns.current_state == :schedule
      refute assigns.entered_via_overview
    end
  end

  describe "an embedded page" do
    test "keeps the embed's parameters and its own path in each patch", %{conn: conn} do
      %{profile: profile} = seed_organiser("1", "url-embed")

      profile
      |> Changeset.change(allowed_embed_domains: ["embedder.test"])
      |> Repo.update!()

      embed = %{
        "embed" => "1",
        "parent-origin" => "https://embedder.test",
        "theme" => "2",
        "layout" => "column"
      }

      {:ok, view, _html} = live(conn, "/#{profile.username}?#{URI.encode_query(embed)}")
      assert live_assigns(view).embedded

      BookingDriver.choose_meeting_type(view, "quick-chat")

      url = BookingTestHelpers.last_patched_url(view)
      assert URI.parse(url).path == "/#{profile.username}"
      assert Map.merge(query(url), embed) == query(url)
      assert query(url)["duration"] == "quick-chat"
    end
  end

  describe "a page that moves on by itself" do
    @theme_id "96"

    test "a remount lands on the details with the type, day and time chosen", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "url-scroll",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Chat", duration_minutes: 60]
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      BookingDriver.choose_meeting_type(view, "long-chat")
      {day, time} = BookingDriver.pick_first_slot(view, on: a_few_days_ahead())

      url = BookingTestHelpers.last_patched_url(view)
      assert %{"duration" => "long-chat", "date" => ^day, "time" => ^time} = query(url)
      refute Map.has_key?(query(url), "step")

      view = remount(url)

      Eventually.eventually(
        fn -> first_value(view, "#you-step", "data-moment-state") == "current" end,
        timeout: 5000
      )

      assigns = live_assigns(view)
      assert assigns.selected_duration == "long-chat"
      assert {assigns.selected_date, assigns.selected_time} == {day, time}
      assert assigns.entered_via_overview
    end
  end

  describe "the visitor's timezone" do
    # A link copied from the address bar and sent on must show its reader
    # times in their own zone, not the sender's.
    test "is left out of the URL while it is the browser's own", %{conn: conn} do
      %{profile: profile} = seed_organiser("1", "url-zone-own")

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"timezone" => "Europe/Berlin"})
        |> live(~p"/#{profile.username}")

      BookingDriver.book(view, meeting_type: "quick-chat", until: :attendee)
      assert live_assigns(view).user_timezone == "Europe/Berlin"

      url = BookingTestHelpers.last_patched_url(view)
      assert query(url)["date"]
      refute Map.has_key?(query(url), "visitor_timezone")

      {:ok, reader, _html} =
        build_conn()
        |> put_connect_params(%{"timezone" => "Asia/Tokyo"})
        |> live(url)

      assert live_assigns(reader).user_timezone == "Asia/Tokyo"
    end

    test "goes in the URL once the visitor chooses another, and wins on a remount", %{
      conn: conn
    } do
      %{profile: profile} = seed_organiser("1", "url-zone-chosen")

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"timezone" => "Europe/Berlin"})
        |> live(~p"/#{profile.username}")

      BookingDriver.book(view, meeting_type: "quick-chat", until: :attendee)
      send(view.pid, {:step_event, :booking, :change_timezone, "America/New_York"})
      Eventually.eventually(fn -> live_assigns(view).user_timezone == "America/New_York" end)

      url = BookingTestHelpers.last_patched_url(view)
      assert query(url)["visitor_timezone"] == "America/New_York"

      {:ok, remounted, _html} =
        build_conn()
        |> put_connect_params(%{"timezone" => "Europe/Berlin"})
        |> live(url)

      assert live_assigns(remounted).user_timezone == "America/New_York"
    end
  end
end
