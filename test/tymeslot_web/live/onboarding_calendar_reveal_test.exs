defmodule TymeslotWeb.OnboardingLive.CalendarRevealTest do
  @moduledoc """
  The reveal of the host's week on the setup stage: read in the background
  once the page has a bookable calendar, on the calendar step and on any
  later step the host lands on, and shown loading, slow, ready or failed.

  The calendar is stubbed at its boundary (`Tymeslot.CalendarMock`), so the
  week is the real `Availability.week_preview/2` over the host's own hours.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import ExUnit.CaptureLog
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Availability
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar, as: CalendarIntegrations
  alias Tymeslot.Mocks.Calendar, as: CalendarFixtures
  alias TymeslotWeb.OnboardingLive.WeekReveal

  setup :verify_on_exit!

  @placeholder_line "Your free times appear here once your calendar is connected."
  @waiting_line "Connected. Your free times will appear on your page."

  # Open 11:00-17:00 every day, in UTC, so the coming week always has times
  # whatever day the suite runs on.
  defp host(opts \\ []) do
    user = insert(:user, onboarding_completed_at: nil)

    profile =
      insert(:profile,
        user: user,
        username: "reveal#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC"
      )

    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    for day <- 1..7 do
      {:ok, _day} =
        WeeklySchedule.create_day_availability(schedule.id, day, %{
          is_available: true,
          start_time: ~T[11:00:00],
          end_time: ~T[17:00:00]
        })
    end

    if Keyword.get(opts, :calendar, true), do: insert(:calendar_integration, user: user)

    %{user: user, profile: profile}
  end

  defp stub_events(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to -> {:ok, events} end)
  end

  defp caption(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(".onboarding-stage-caption")
    |> Floki.text()
    |> String.trim()
  end

  defp continue_disabled?(view),
    do: has_element?(view, "button[phx-click='next_step'][disabled]")

  describe "a bookable calendar" do
    test "starts the reveal and the caption shows the week", %{conn: conn} do
      %{user: user, profile: profile} = host()

      # Two days out, clear of any minimum notice.
      busy_day = Date.add(Date.utc_today(), 2)

      stub_events([
        CalendarFixtures.event(
          start_time: DateTime.new!(busy_day, ~T[12:00:00], "Etc/UTC"),
          end_time: DateTime.new!(busy_day, ~T[13:00:00], "Etc/UTC")
        )
      ])

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      render_async(view)

      {:ok, preview} = Availability.week_preview(profile)
      assert preview.slot_count > 0
      weekday = Calendar.strftime(busy_day, "%A")

      assert caption(view) =~
               ~r/^Your #{weekday} .+ is already blocked\. #{preview.slot_count} open slots this week\.$/

      assert has_element?(view, ~s([data-role="stage-announcement"]), caption(view))
      # The times are drawn in the list the reveal's bumped key names.
      assert has_element?(view, "#stage-times-1 [data-reveal-item]")
      refute continue_disabled?(view)
    end

    test "a later step the host lands on reads the week too", %{conn: conn} do
      %{user: user} = host()
      stub_events([])
      conn = log_in_user(conn, user)

      # The first paint already shows it loading, never the line for a host
      # without a calendar.
      static = conn |> get("/onboarding/meeting") |> html_response(200)
      assert static =~ "Reading your calendar"
      refute static =~ @placeholder_line

      {:ok, view, _html} = live(conn, "/onboarding/meeting")
      render_async(view)

      assert caption(view) =~ ~r/^\d+ open slots this week\.$/
      refute render(view) =~ @placeholder_line

      # Moving on keeps the week rather than reading it again.
      click_continue(view)
      assert has_element?(view, "#stage-times-1 [data-reveal-item]")
      refute has_element?(view, "#stage-times-2")
    end

    test "a failing read never blocks Continue", %{conn: conn} do
      %{user: user} = host()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        {:error, :timeout}
      end)

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      render_async(view)

      assert caption(view) == ""
      assert has_element?(view, ~s([data-week-state="failed"]), @waiting_line)
      refute continue_disabled?(view)
    end

    test "a read that raises is shown as failed", %{conn: conn} do
      %{user: user} = host()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        raise "calendar down"
      end)

      capture_log(fn ->
        {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
        render_async(view)

        assert has_element?(view, ~s([data-week-state="failed"]), @waiting_line)
        refute continue_disabled?(view)
      end)
    end

    # The read's own failures come back as errors (the calendar cache turns
    # a raise into one), so a crash of the task itself is driven directly.
    test "a read whose task exits is shown as failed" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_user: %{id: 1},
          reveal_key: 1,
          stage_week: %{state: :loading, preview: nil}
        }
      }

      log =
        capture_log(fn ->
          assert %{assigns: %{stage_week: %{state: :failed, preview: nil}}} =
                   WeekReveal.handle_result({:exit, :killed}, socket)
        end)

      assert log =~ "Onboarding week preview crashed"
    end

    test "an answer to an older read is dropped" do
      # A debug fixture bumps the key, so the answer of the read it stood in
      # for, already on its way, must not replace the fixture's week.
      week = %{state: :slow, preview: nil}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, reveal_key: 2, stage_week: week}
      }

      preview = %Tymeslot.Availability.WeekPreview{days: [], slot_count: 0, first_busy: nil}

      assert WeekReveal.handle_result({:ok, {1, {:ok, preview}}}, socket).assigns.stage_week ==
               week
    end

    test "the first paint never reads the calendar", %{conn: conn} do
      %{user: user} = host()

      expect(CalendarMock, :get_events_for_range_fresh, 0, fn _user_id, _from, _to ->
        {:ok, []}
      end)

      html =
        conn |> log_in_user(user) |> get("/onboarding/connect_calendar") |> html_response(200)

      assert html =~ ~s(data-week-state="loading")
    end

    test "an OAuth return to the share step reveals the week", %{conn: conn} do
      %{user: user} = host()
      stub_events([])

      {:ok, view, _html} =
        live(log_in_user(conn, user), "/onboarding/connect_calendar?return=share")

      render_async(view)

      assert caption(view) =~ ~r/^\d+ open slots this week\.$/
    end

    test "a slow timer that fires after the week arrived changes nothing", %{conn: conn} do
      %{user: user} = host()
      stub_events([])

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      render_async(view)
      ready = caption(view)
      assert ready =~ ~r/^\d+ open slots this week\.$/

      # The timer armed for this read, arriving late.
      send(view.pid, {:week_preview_slow, 1})

      assert caption(view) == ready
      assert has_element?(view, ~s([data-week-state="ready"]))
    end

    test "a slow read shows the slow state, then the week once it arrives", %{conn: conn} do
      original = Application.get_env(:tymeslot, :onboarding_week_slow_after_ms)
      Application.put_env(:tymeslot, :onboarding_week_slow_after_ms, 0)

      on_exit(fn ->
        if original,
          do: Application.put_env(:tymeslot, :onboarding_week_slow_after_ms, original),
          else: Application.delete_env(:tymeslot, :onboarding_week_slow_after_ms)
      end)

      %{user: user} = host()
      test_pid = self()

      # The read waits for the test's word, so the timer is certain to fire
      # first.
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, {:reading, self()})

        receive do
          :answer -> {:ok, []}
        end
      end)

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      assert_receive {:reading, reader}

      assert render(view) =~ @waiting_line
      assert caption(view) == ""

      send(reader, :answer)
      render_async(view)

      refute render(view) =~ @waiting_line
      assert caption(view) =~ ~r/^\d+ open slots this week\.$/
    end
  end

  describe "Apple Calendar" do
    # A 207 with one discoverable calendar answers every PROPFIND of the
    # discovery chain, as in the CalDAV discovery tests.
    @propfind_calendar_response """
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>/calendars/user/personal/</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>Personal</D:displayname>
            <D:resourcetype>
              <D:collection/>
              <C:calendar/>
            </D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    test "is its own choice, asks for no server, and its connect starts the reveal",
         %{conn: conn} do
      %{user: user} = host(calendar: false)

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn _method, url, _body, _headers, _opts ->
        send(test_pid, {:caldav_request, URI.parse(url).host})
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      stub_events([])

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")

      assert has_element?(view, ~s{button[phx-value-option="apple"]}, "Apple Calendar")
      assert has_element?(view, ~s{button[phx-value-option="apple"] img[src*="apple"]})
      assert continue_disabled?(view)

      open_apple_form(view)

      assert has_element?(view, "#apple-form")
      refute has_element?(view, "#apple-form input[name='url']")
      # Password managers can fill the Apple ID and the saved app password.
      assert has_element?(view, "#apple-form input[name='username'][autocomplete='username']")

      assert has_element?(
               view,
               "#apple-form input[name='password'][autocomplete='current-password']"
             )

      # Three short steps, the second opening Apple's account page in a new tab.
      assert [_first, _second, _third] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("#apple-form [data-role='apple-steps'] > li")

      assert has_element?(
               view,
               "#apple-form [data-role='apple-steps'] li:nth-child(2) a[href='https://account.apple.com'][target='_blank'][rel~='noopener']",
               "Open your Apple Account"
             )

      view
      |> form("#apple-form", %{
        "username" => "host@icloud.com",
        "password" => "abcd-efgh-ijkl-mnop"
      })
      |> render_submit()

      # The discovery, then the week it unlocks.
      render_async(view, 2000)
      render_async(view, 2000)

      assert [%{provider: "apple"}] = CalendarIntegrations.list_integrations(user.id)
      # The form has no server: the calendars were looked for on iCloud's.
      assert_received {:caldav_request, "caldav.icloud.com"}
      assert caption(view) =~ ~r/^\d+ open slots this week\.$/
      refute continue_disabled?(view)
    end

    test "a paused CalDAV calendar reconnects from its row and reveals the week",
         %{conn: conn} do
      %{user: user} = host(calendar: false)

      paused =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://cal.example.com",
          is_active: false,
          calendar_paths: ["/calendars/user/personal/"]
        )

      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      stub_events([])

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      assert continue_disabled?(view)

      view
      |> element(~s{button[phx-click="reconnect_calendar"][phx-value-id="#{paused.id}"]})
      |> render_click()

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "new-secret"
      })
      |> render_submit()

      # The reconnect, then the week it unlocks.
      render_async(view, 2000)
      render_async(view, 2000)

      assert [%{id: id, is_active: true}] = CalendarIntegrations.list_integrations(user.id)
      assert id == paused.id
      assert has_element?(view, ~s([data-calendar-state="connected"]))
      refute has_element?(view, ~s([data-role="calendar-not-bookable"]))
      assert caption(view) =~ ~r/^\d+ open slots this week\.$/
      refute continue_disabled?(view)
    end

    test "names the Apple ID email when it is missing", %{conn: conn} do
      %{user: user} = host(calendar: false)
      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      open_apple_form(view)

      html =
        view
        |> form("#apple-form", %{"username" => "", "password" => ""})
        |> render_change()

      assert html =~ "Apple ID email is required"
      assert html =~ "Password is required"
      refute html =~ "Server URL is required"
    end
  end
end
