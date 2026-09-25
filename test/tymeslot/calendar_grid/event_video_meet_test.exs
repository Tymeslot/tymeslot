defmodule Tymeslot.CalendarGrid.EventVideoMeetTest do
  @moduledoc """
  Changing the video of a Google event whose Meet comes from the calendar's
  own Google account: Google makes the conference through the update's
  `conferenceData`, the event is read back once for its link, and moving away
  takes the conference off in the same write.

  The calendar write is stubbed at `Tymeslot.CalendarMock`, the read back at
  `GoogleCalendarAPIMock`. The wire shape of the update itself is pinned
  against `Google.CalendarAPI` with HTTP stubbed at `Tymeslot.HTTPClientMock`.

  Whether Google removes a conference from a `PUT` sent with
  `conferenceDataVersion=1` and no `conferenceData` could not be checked
  against a real account; these tests pin the request, not Google's answer.
  """

  # Not async: the calendar providers' circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @account "google-account-1"
  @meet_url "https://meet.google.com/abc-defg-hij"
  @zoom_url "https://zoom.us/j/86360699337"
  @new_url "https://video.example.com/join/room-123"

  setup do
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: @account,
        oauth_scope: "https://www.googleapis.com/auth/calendar",
        default_booking_calendar_id: "primary"
      )

    meet =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        provider_account_id: @account
      )

    %{user: user, calendar: calendar, meet: meet}
  end

  describe "switching a Google event to Meet from the same account" do
    test "asks Google for the conference and caches the link it made", ctx do
      zoom = insert(:video_integration, user: ctx.user, provider: "zoom")

      event =
        insert_event(ctx.calendar, %{
          description: "Agenda\n\nJoin video call: #{@zoom_url}",
          video_link: @zoom_url,
          video_integration_id: zoom.id
        })

      expect_update()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, "primary", "googlehex1" ->
        {:ok, google_event(conference: @meet_url)}
      end)

      assert {:ok, @meet_url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.meet.id)

      assert_received {:update, payload}

      assert %{createRequest: %{conferenceSolutionKey: %{type: "hangoutsMeet"}}} =
               payload.conference_data

      # Meet's link lives on the event's own conference, not in its text.
      assert payload.description == "Agenda"

      row = reload(event)
      assert {row.video_link, row.video_integration_id} == {@meet_url, ctx.meet.id}

      assert_enqueued(worker: VideoSyncWorker, args: %{"room_id" => "86360699337"})
    end

    test "keeps the integration without a link when Google has not made one yet", ctx do
      event = insert_event(ctx.calendar)
      expect_update()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar, _id ->
        {:ok, google_event(conference: nil)}
      end)

      assert {:error, :meet_link_pending} =
               CalendarGrid.change_event_video(ctx.user.id, event, ctx.meet.id)

      row = reload(event)
      assert {row.video_link, row.video_integration_id} == {nil, ctx.meet.id}
    end
  end

  describe "switching away from Meet from the same account" do
    setup ctx do
      event =
        insert_event(ctx.calendar, %{
          description: "Agenda",
          video_link: @meet_url,
          video_integration_id: ctx.meet.id
        })

      expect(GoogleCalendarAPIMock, :get_event, 0, fn _integration, _calendar, _id -> :ok end)
      %{event: event}
    end

    test "to None, takes the conference off the event", ctx do
      expect_update()

      assert {:ok, nil} = CalendarGrid.change_event_video(ctx.user.id, ctx.event, nil)

      assert_received {:update, payload}
      assert payload.conference_data == ConferenceData.remove()
      assert reload(ctx.event).video_link == nil
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "to another room, takes the conference off in the same write", ctx do
      mirotalk = insert(:video_integration, user: ctx.user, provider: "mirotalk")
      body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => @new_url})

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: body}}
      end)

      expect_update()

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, mirotalk.id)

      assert_received {:update, payload}
      assert payload.conference_data == ConferenceData.remove()
      assert payload.description == "Agenda\n\nJoin video call: #{@new_url}"
    end
  end

  describe "a Google event whose Meet is from another account" do
    test "removing it rewrites the description and leaves the conference alone", ctx do
      other =
        insert(:video_integration,
          user: ctx.user,
          provider: "google_meet",
          provider_account_id: "another-account"
        )

      event =
        insert_event(ctx.calendar, %{
          description: "Agenda\n\nJoin video call: #{@meet_url}",
          video_link: @meet_url,
          video_integration_id: other.id
        })

      expect_update()

      assert {:ok, nil} = CalendarGrid.change_event_video(ctx.user.id, event, nil)

      assert_received {:update, payload}
      assert payload.description == "Agenda"
      refute Map.has_key?(payload, :conference_data)
    end
  end

  describe "the update Google receives" do
    setup ctx do
      integration =
        insert(:calendar_integration,
          user: ctx.user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      %{integration: integration}
    end

    test "asks for a Meet conference with conferenceDataVersion=1", %{integration: integration} do
      expect_put(fn url, body ->
        assert url =~ "conferenceDataVersion=1"

        assert body["conferenceData"]["createRequest"]["conferenceSolutionKey"]["type"] ==
                 "hangoutsMeet"
      end)

      write_update(integration, %{conference_data: ConferenceData.create_request()})
    end

    test "removes the conference with conferenceDataVersion=1 and no conferenceData", %{
      integration: integration
    } do
      expect_put(fn url, body ->
        assert url =~ "conferenceDataVersion=1"
        refute Map.has_key?(body, "conferenceData")
      end)

      write_update(integration, %{conference_data: ConferenceData.remove()})
    end

    test "leaves the conference alone on any other update", %{integration: integration} do
      expect_put(fn url, _body -> refute url =~ "conferenceDataVersion" end)
      write_update(integration, %{})
    end
  end

  defp write_update(integration, extra) do
    event_data =
      Map.merge(
        %{
          summary: "Planning",
          start_time: ~U[2026-06-01 09:00:00Z],
          end_time: ~U[2026-06-01 10:00:00Z]
        },
        extra
      )

    assert {:ok, _event} =
             CalendarAPI.update_event(integration, "primary", "event-abc", event_data)
  end

  defp expect_put(check) do
    expect(Tymeslot.HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
      check.(url, Jason.decode!(body))
      {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "event-abc"})}}
    end)
  end

  defp expect_update do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:update, payload})
      :ok
    end)
  end

  defp google_event(conference: url) do
    base = %{
      "id" => "googlehex1",
      "iCalUID" => "googlehex1@google.com",
      "status" => "confirmed",
      "summary" => "Planning",
      "start" => %{"dateTime" => "2026-06-01T09:00:00Z"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00Z"}
    }

    if url,
      do:
        Map.put(base, "conferenceData", %{
          "entryPoints" => [%{"entryPointType" => "video", "uri" => url}]
        }),
      else: base
  end

  defp insert_event(calendar, attrs \\ %{}) do
    defaults = %{
      calendar_integration: calendar,
      uid: "googlehex1@google.com",
      provider: "google",
      provider_event_id: "googlehex1",
      provider_calendar_id: "primary",
      summary: "Planning",
      description: "Agenda",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp reload(event) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)
    row
  end
end
