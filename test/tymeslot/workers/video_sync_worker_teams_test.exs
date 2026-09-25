defmodule Tymeslot.Workers.VideoSyncWorkerTeamsTest do
  @moduledoc """
  The video-room sync worker for a Microsoft Teams meeting that lives on the
  booking's own Outlook event (same Microsoft account as the booking's
  calendar), where the room id is the calendar event id. Calendar sync owns
  that event, so the worker must never move or delete it through the provider.
  The general sync behaviour is in `Tymeslot.Workers.VideoSyncWorkerTest`.
  """

  # Not async, like `Tymeslot.Workers.VideoSyncWorkerTest`: a regression here
  # would call Graph through the application-wide video circuit breaker.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :workers
  @moduletag :video

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  describe "perform/1" do
    # The room is the booking's Outlook event itself (same Microsoft account),
    # so calendar sync owns it: moving it here would race the calendar's own
    # write, and deleting it would delete the booking's event.
    setup do
      %{user: user} = create_user_with_profile()
      integration = insert_teams_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "teams",
          video_room_id: "AAMk-booking-event",
          provider_event_id: "AAMk-booking-event",
          video_room_enabled: true,
          organizer_video_url: "https://teams.microsoft.com/l/meetup-join/organiser",
          attendee_video_url: "https://teams.microsoft.com/l/meetup-join/attendee"
        })

      test_pid = self()
      stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      stub(HTTPClientMock, :request, fn method, url, _body, _headers, _opts ->
        send(test_pid, {:graph_call, method, url})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      %{meeting: meeting}
    end

    test "an update leaves the provider alone and keeps the room", %{meeting: meeting} do
      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      refute_received {:graph_call, _method, _url}
      assert Repo.reload!(meeting).video_room_id == "AAMk-booking-event"
    end

    test "a delete clears the local room without deleting the booking's event",
         %{meeting: meeting} do
      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      refute_received {:graph_call, _method, _url}

      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == nil
      refute reloaded.video_room_enabled
      assert reloaded.attendee_video_url == nil
      # The event is still the booking's, for calendar sync to cancel.
      assert reloaded.provider_event_id == "AAMk-booking-event"
    end
  end

  defp insert_teams_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Teams",
      provider: "teams",
      base_url: nil,
      api_key_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
      provider_account_id: "entra-oid-1"
    )
  end
end
