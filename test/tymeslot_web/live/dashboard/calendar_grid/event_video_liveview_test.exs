defmodule TymeslotWeb.Dashboard.CalendarGrid.EventVideoLiveViewTest do
  @moduledoc """
  Changing an event's video room from the detail modal, end to end: the
  organiser's choice in the video selector, the room it provisions, the
  description written to the calendar, and what the modal shows once the
  background Task has answered.

  The room is created through the real MiroTalk adapter with HTTP stubbed at
  `Tymeslot.HTTPClientMock`; the calendar write reaches `Tymeslot.CalendarMock`.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  # Video room and provider writes run in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "the video selector in the event editor" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Video Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          video_integration_id: nil
        })

      {:ok, event: event, video_integration: video_integration}
    end

    test "shows video selector in edit modal", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "update_edit_video"
      assert html =~ video_integration.name
      assert html =~ "None"
    end

    test "choosing a video integration creates a room and saves its link", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      stub_room_created("https://video.example.com/join/room-123")
      expect_provider_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      payload = await_provider_update(lv)
      assert payload.description == "Join video call: https://video.example.com/join/room-123"

      html = render(lv)
      assert html =~ "Video room created."
      refute html =~ "notify-prompt-modal"

      assert has_element?(
               lv,
               ~s|button[phx-value-video_integration_id="#{video_integration.id}"].border-turquoise-400|
             )

      {:ok, row} =
        ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)

      assert row.video_link == "https://video.example.com/join/room-123"
      assert row.video_integration_id == video_integration.id
    end

    test "choosing None removes the event's video link", %{
      conn: conn,
      user: user,
      video_integration: video_integration
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      link = "https://video.example.com/join/old-room"

      event =
        insert_event(integration, %{
          summary: "Linked Event",
          description: "Join video call: #{link}",
          start_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[14:00:00], "Etc/UTC"),
          all_day: false,
          video_link: link,
          video_integration_id: video_integration.id
        })

      expect_provider_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{"video_integration_id" => ""})

      payload = await_provider_update(lv)
      assert payload.description == ""

      assert render(lv) =~ "Video link removed."
      assert has_element?(lv, ~s|button[phx-value-video_integration_id=""].border-turquoise-400|)

      refute has_element?(
               lv,
               ~s|button[phx-value-video_integration_id="#{video_integration.id}"].border-turquoise-400|
             )

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.video_link == nil
      assert row.video_integration_id == nil
    end

    test "a room without a join link leaves the event's video unchanged", %{
      conn: conn,
      event: event,
      video_integration: video_integration
    } do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        send(test_pid, {:room_requested, self()})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"room_id" => "room-123"})}}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      assert_receive {:room_requested, task_pid}, @task_timeout
      await_task(lv, task_pid)

      assert render(lv) =~ "did not return a meeting link"
      assert has_element?(lv, ~s|button[phx-value-video_integration_id=""].border-turquoise-400|)

      {:ok, row} =
        ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)

      assert row.video_integration_id == nil
    end
  end

  describe "re-picking the choice the event already has" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user, is_active: true)

      {:ok, integration: integration, video_integration: video_integration}
    end

    test "leaves the organiser's edit allowance alone", %{
      conn: conn,
      integration: integration,
      video_integration: video_integration
    } do
      link = "https://video.example.com/join/current-room"

      event =
        insert_event(integration, %{
          summary: "Linked Event",
          description: "Join video call: #{link}",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          video_link: link,
          video_integration_id: video_integration.id
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      # An organiser may edit a calendar event 30 times in five minutes.
      # Clicking the button that is already active is not an edit, so it must
      # not eat into that, or an idle hand leaves no allowance for a real one.
      for _click <- 1..30 do
        lv
        |> element("#calendar-grid")
        |> render_hook("update_edit_video", %{
          "video_integration_id" => to_string(video_integration.id)
        })
      end

      stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      html = render(lv)
      assert html =~ "Changes saved."
      refute html =~ "Too many edits."
      refute html =~ "Video room created."
    end

    test "choosing None on an event that has no video says nothing happened", %{
      conn: conn,
      integration: integration
    } do
      event =
        insert_event(integration, %{
          summary: "Plain Event",
          description: "Agenda",
          start_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          all_day: false,
          video_link: nil,
          video_integration_id: nil
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{"video_integration_id" => ""})

      html = render(lv)
      refute html =~ "Video link removed."
      refute html =~ "Could not change the video link"
    end

    test "still provisions the room a failed earlier attempt left missing", %{
      conn: conn,
      integration: integration,
      video_integration: video_integration
    } do
      url = "https://video.example.com/join/repaired-room"

      event =
        insert_event(integration, %{
          summary: "Half-linked Event",
          description: "Agenda",
          start_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[17:00:00], "Etc/UTC"),
          all_day: false,
          video_link: nil,
          video_integration_id: video_integration.id
        })

      stub_room_created(url)
      expect_provider_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      payload = await_provider_update(lv)
      assert payload.description == "Agenda\n\nJoin video call: #{url}"
      assert render(lv) =~ "Video room created."

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.video_link == url
    end
  end

  describe "telling attendees about a video change" do
    test "an event with attendees offers to notify them, and confirming emails them", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user, is_active: true)

      event =
        insert_event(integration, %{
          summary: "Team Sync",
          description: "Agenda",
          attendees: [%{"email" => "guest@example.com", "name" => "Guest"}],
          start_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC"),
          all_day: false,
          video_link: nil,
          video_integration_id: nil
        })

      stub_room_created("https://video.example.com/join/room-123")
      expect_provider_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      await_provider_update(lv)

      html = render(lv)
      assert html =~ "notify-prompt-modal"
      assert html =~ "Notify 1 attendee of this change?"
      refute_enqueued(worker: Worker)

      lv
      |> element("#calendar-grid")
      |> render_hook("notify_prompt_confirm", %{})

      args = %{
        "event_id" => event.id,
        "kind" => "provider_calendar_event",
        "action" => "update"
      }

      assert_enqueued(worker: Worker, args: args)

      # Draining that job is the half the organiser was actually promised.
      # The event has never been notified before: nothing seeds
      # `last_notified_state`, so it is still `%{}` here, which is the state
      # every event reaches its first edit in.
      assert :ok = perform_job(Worker, args)

      update_jobs =
        [worker: EmailWorker]
        |> all_enqueued()
        |> Enum.filter(&(&1.args["action"] == "send_event_update_notification"))

      assert [%{args: %{"attendee_emails" => ["guest@example.com"]}}] = update_jobs
    end
  end

  describe "switching a Google event to Meet from the calendar's own account" do
    test "shows the event as written, with no join line the calendar does not have", %{
      conn: conn,
      user: user
    } do
      account = "google-account-#{System.unique_integer([:positive])}"
      meet_url = "https://meet.google.com/abc-defg-hij"
      zoom_url = "https://zoom.us/j/86360699337"

      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: account,
          oauth_scope: "https://www.googleapis.com/auth/calendar",
          default_booking_calendar_id: "primary",
          is_active: true
        )

      zoom = insert(:video_integration, user: user, provider: "zoom", is_active: true)

      meet =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: account,
          is_active: true
        )

      event =
        insert_event(calendar, %{
          summary: "Planning",
          provider: "google",
          provider_event_id: "googlehex1",
          provider_calendar_id: "primary",
          description: "Agenda\n\nJoin video call: #{zoom_url}",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false,
          video_link: zoom_url,
          video_integration_id: zoom.id
        })

      expect_provider_update()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, "primary", "googlehex1" ->
        {:ok,
         %{
           "id" => "googlehex1",
           "status" => "confirmed",
           "summary" => "Planning",
           "start" => %{"dateTime" => DateTime.to_iso8601(event.start_at)},
           "end" => %{"dateTime" => DateTime.to_iso8601(event.end_at)},
           "conferenceData" => %{
             "entryPoints" => [%{"entryPointType" => "video", "uri" => meet_url}]
           }
         }}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{"video_integration_id" => to_string(meet.id)})

      assert await_provider_update(lv).description == "Agenda"

      html = render(lv)
      assert html =~ "Video room created."
      refute html =~ "Join video call:"

      assert has_element?(
               lv,
               ~s|button[phx-value-video_integration_id="#{meet.id}"].border-turquoise-400|
             )

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(calendar.id, event.uid)
      assert {row.description, row.video_link} == {"Agenda", meet_url}
    end
  end

  describe "the video selector on the calendar copy of a booking" do
    test "refuses the change, says why, and leaves the event's link alone", %{
      conn: conn,
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user, is_active: true)
      link = "https://video.example.com/join/booking-room"

      event =
        insert_event(integration, %{
          summary: "Booked Call",
          description: "Join video call: #{link}",
          start_at: DateTime.new!(Date.utc_today(), ~T[15:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[16:00:00], "Etc/UTC"),
          all_day: false,
          video_link: link,
          video_integration_id: nil
        })

      insert(:meeting, calendar_integration_id: integration.id, uid: event.uid)

      # Neither the video provider nor the calendar may be reached.
      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :ok end)
      expect(Tymeslot.CalendarMock, :update_event, 0, fn _uid, _payload, _context -> :ok end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_edit_video", %{
        "video_integration_id" => to_string(video_integration.id)
      })

      assert render(lv) =~ "This event is a booking, so its video link belongs to the booking."

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert {row.video_link, row.video_integration_id} == {link, nil}
    end
  end

  defp stub_room_created(url) do
    body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => url})

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end

  defp expect_provider_update do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)
  end

  # Waits for the Task that made the provider write, then lets the LiveView
  # handle its result and the grid component apply it.
  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    await_task(lv, task_pid)
    payload
  end

  defp await_task(lv, task_pid) do
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
