defmodule Tymeslot.Workers.VideoRoomWorkerTeamsTest do
  @moduledoc """
  Microsoft Teams room creation through the real `VideoRoomWorker`,
  `Tymeslot.Meetings.VideoRooms` and Teams provider, with only Graph (HTTP) and
  the OAuth helper mocked.

  Two regressions are guarded here. A Teams room used to overwrite the
  booking's `uid` with its Graph event id, so the cancel and reschedule links
  already sent to the attendee stopped resolving (#143). And a Teams room on
  the same Microsoft account as the booking's Outlook calendar used to create a
  second event beside the booking's own (#145).
  """

  # Not async: room creation runs through the application-wide Teams circuit
  # breaker, which DataCase resets only between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video
  @moduletag :integration

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker, VideoSyncWorker}

  setup :verify_on_exit!

  @account_id "entra-oid-organiser"
  @graph "https://graph.microsoft.com/v1.0"
  @live_join_url "https://teams.live.com/meet/9377?p=Xy12AbCd"

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "teams-host")

    video =
      insert(:video_integration,
        user: user,
        name: "Teams",
        provider: "teams",
        base_url: nil,
        api_key_encrypted: nil,
        access_token_encrypted: Encryption.encrypt("graph-access-token"),
        refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
        provider_account_id: @account_id
      )

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    # Every Graph request is reported to the test, which then asserts on
    # exactly which ones were made.
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:graph, method, url, body})
      event_id = graph_event_id(method, url)

      {:ok,
       %Req.Response{
         status: if(method == :post, do: 201, else: 200),
         body:
           Jason.encode!(%{
             "id" => event_id,
             "onlineMeeting" => %{
               "joinUrl" => "https://teams.microsoft.com/l/meetup-join/#{event_id}"
             }
           })
       }}
    end)

    %{user: user, profile: profile, video: video}
  end

  describe "a Teams meeting with an event of its own" do
    setup %{user: user, profile: profile, video: video} do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:error, :no_integration}
      end)

      %{meeting: insert_booking(user, profile, video)}
    end

    test "keeps the booking's uid, so its emailed links still resolve", %{
      user: user,
      meeting: meeting
    } do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "AAMk-own-event"
      assert updated.meeting_url =~ "teams.microsoft.com"

      assert updated.uid == meeting.uid
      assert uid_in_link(updated.cancel_url) == updated.uid
      assert uid_in_link(updated.reschedule_url) == updated.uid

      assert {:ok, %MeetingSchema{id: id}} =
               Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id)

      assert id == meeting.id
    end

    test "creates the Graph event with the booking's title and times", %{meeting: meeting} do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      assert_received {:graph, :post, url, body}
      assert url == @graph <> "/me/events"

      sent = Jason.decode!(body)
      assert sent["subject"] == "Quarterly review with Ada"
      assert sent["isOnlineMeeting"] == true
      assert sent_time(sent["start"]) == meeting.start_time
      assert sent_time(sent["end"]) == meeting.end_time

      refute_received {:graph, _method, _url, _body}
    end
  end

  describe "a Teams meeting on the same account as the booking's Outlook calendar" do
    setup %{user: user, profile: profile, video: video} do
      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: @account_id
        )

      meeting = insert_booking(user, profile, video)

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn
        %MeetingSchema{id: id} when id == meeting.id ->
          {:ok, %{integration_id: calendar.id, calendar_path: "primary"}}
      end)

      %{meeting: meeting, calendar: calendar}
    end

    test "waits for the booking's calendar event instead of creating a second one", %{
      meeting: meeting
    } do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      refute_received {:graph, _method, _url, _body}
      # The wait is a fresh job a few seconds out, not a snooze of this one.
      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id},
        scheduled_at: {DateTime.add(DateTime.utc_now(), 3), delta: 2}
      )

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == nil
      assert updated.uid == meeting.uid
    end

    # Snoozes count as executions, and `Recovery` announces a booking without
    # its link at the fifth: a wait of a dozen seconds must not get there.
    test "waiting for the booking's event late in a job's life neither announces the booking without its link nor loses the announcement",
         %{meeting: meeting} do
      args = %{"meeting_id" => meeting.id, "announce" => true}

      assert :ok = perform_job(VideoRoomWorker, args, meta: %{"snoozed" => 4})

      refute_enqueued(worker: Tymeslot.Workers.EmailWorker)
      assert Repo.get!(MeetingSchema, meeting.id).announced_at == nil
      assert_enqueued(worker: VideoRoomWorker, args: args)
    end

    test "logs no error while it waits for the booking's calendar event", %{meeting: meeting} do
      errors =
        capture_log([level: :error], fn ->
          assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
        end)

      assert errors == ""
    end

    test "attaches the meeting to the booking's event once calendar sync has written it", %{
      meeting: meeting,
      calendar: calendar
    } do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      # What `CalendarEventSync` records once the booking's event exists.
      meeting
      |> Changeset.change(
        calendar_integration_id: calendar.id,
        calendar_path: "primary",
        provider_event_id: "AAMk-booking-event"
      )
      |> Repo.update!()

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      assert_received {:graph, :patch, url, body}
      assert url == @graph <> "/me/events/AAMk-booking-event"
      # Only the online meeting is switched on: calendar sync owns the rest.
      assert %{"isOnlineMeeting" => true} = sent = Jason.decode!(body)
      refute Map.has_key?(sent, "subject")
      refute_received {:graph, _method, _url, _body}

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "AAMk-booking-event"
      assert updated.video_room_id == updated.provider_event_id
      assert updated.meeting_url =~ "teams.microsoft.com"
      assert updated.uid == meeting.uid
    end

    test "gives the meeting an event of its own once the booking's event is two minutes overdue",
         %{meeting: meeting} do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
      refute_received {:graph, _method, _url, _body}

      # The calendar job never wrote the booking's event, and the grace period
      # has run out since the booking was made.
      backdate(meeting, 121)

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      assert_received {:graph, :post, url, body}
      assert url == @graph <> "/me/events"
      sent = Jason.decode!(body)
      assert sent["subject"] == "Quarterly review with Ada"
      assert sent["isOnlineMeeting"] == true
      assert sent_time(sent["start"]) == meeting.start_time
      refute_received {:graph, _method, _url, _body}

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "AAMk-own-event"
      assert updated.provider_event_id == nil
      assert updated.uid == meeting.uid
    end

    test "hands the booking's event to calendar sync to replace when the booking left Teams while the meeting was attached",
         %{meeting: meeting, calendar: calendar} do
      meeting =
        meeting
        |> Changeset.change(
          calendar_integration_id: calendar.id,
          calendar_path: "primary",
          provider_event_id: "AAMk-booking-event"
        )
        |> Repo.update!()

      # Graph switches the online meeting on while the booking is rescheduled
      # to a location without video: the event now carries a Teams meeting the
      # booking no longer has.
      stub(Tymeslot.HTTPClientMock, :request, fn :patch, url, _body, _headers, _opts ->
        meeting |> Changeset.change(video_integration_id: nil) |> Repo.update!()
        event_id = graph_event_id(:patch, url)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => event_id,
               "onlineMeeting" => %{
                 "joinUrl" => "https://teams.microsoft.com/l/meetup-join/#{event_id}"
               }
             })
         }}
      end)

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      # Deleting the room would delete the booking's own event: calendar sync
      # replaces it with one without the meeting instead.
      refute_enqueued(worker: VideoSyncWorker)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{
          "action" => "replace",
          "meeting_id" => meeting.id,
          "event_id" => "AAMk-booking-event"
        }
      )

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == nil
      assert updated.provider_event_id == "AAMk-booking-event"
    end
  end

  # A personal Microsoft account has no Teams for Business: Graph picks the
  # consumer Teams itself and answers with a teams.live.com link, which is what
  # a live run against a personal account returned.
  describe "a Teams meeting on a personal Microsoft account" do
    setup %{user: user, profile: profile, video: video} do
      video =
        video
        |> Changeset.change(
          tenant_id_encrypted: Encryption.encrypt(MicrosoftConfig.consumer_tenant_id())
        )
        |> Repo.update!()

      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: @account_id
        )

      meeting =
        user
        |> insert_booking(profile, video)
        |> Changeset.change(
          calendar_integration_id: calendar.id,
          calendar_path: "primary",
          provider_event_id: "AAMk-booking-event"
        )
        |> Repo.update!()

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:ok, %{integration_id: calendar.id, calendar_path: "primary"}}
      end)

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
        send(test_pid, {:graph, method, url, body})

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => graph_event_id(method, url),
               "onlineMeeting" => %{"joinUrl" => @live_join_url}
             })
         }}
      end)

      %{meeting: meeting}
    end

    test "attaches the meeting without naming a provider and keeps the teams.live.com link",
         %{meeting: meeting} do
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      assert_received {:graph, :patch, url, body}
      assert url == @graph <> "/me/events/AAMk-booking-event"
      assert Jason.decode!(body) == %{"isOnlineMeeting" => true}

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "AAMk-booking-event"
      assert updated.meeting_url == @live_join_url
      assert updated.attendee_video_url =~ ~r{^https://teams\.live\.com/meet/9377\?}
      assert updated.organizer_video_url =~ ~r{^https://teams\.live\.com/meet/9377\?}
    end
  end

  defp insert_booking(user, profile, video) do
    uid = UUID.generate()
    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
    base = "https://tymeslot.example/#{profile.username}/meeting/#{uid}"

    insert(:meeting,
      uid: uid,
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: video.id,
      title: "Quarterly review",
      summary: "Quarterly review with Ada",
      start_time: start_time,
      end_time: DateTime.add(start_time, 45, :minute),
      duration: 45,
      cancel_url: base <> "/cancel",
      reschedule_url: base <> "/reschedule"
    )
  end

  defp backdate(meeting, seconds) do
    inserted_at =
      DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

    meeting |> Changeset.change(inserted_at: inserted_at) |> Repo.update!()
  end

  # A new event gets its id from Graph; an existing one keeps the id it was
  # addressed by.
  defp graph_event_id(:post, _url), do: "AAMk-own-event"
  defp graph_event_id(_method, url), do: url |> String.split("/") |> List.last()

  defp uid_in_link(url) do
    [_all, uid] = Regex.run(~r{/meeting/([^/]+)/(?:cancel|reschedule)$}, url)
    uid
  end

  defp sent_time(%{"dateTime" => date_time, "timeZone" => "UTC"}) do
    {:ok, parsed, 0} = DateTime.from_iso8601(date_time)
    parsed
  end
end
