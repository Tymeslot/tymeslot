defmodule Tymeslot.Workers.VideoRoomWorkerCreationTimeoutTest do
  @moduledoc """
  How long the room job waits for a provider to create a room.

  Giving up on a call the provider is still answering abandons a room the
  provider may already have made, and the retry makes a second one. The job
  therefore waits longer than the network budget of the provider the meeting
  actually uses, and only that long, so one slow provider does not hold the
  queue for bookings on every other.
  """

  # Not async: the job calls the provider from a supervised task, and the Talk
  # circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoRoomWorker

  @server "https://slow.talk.example.com"
  @room_api @server <> "/ocs/v2.php/apps/spreed/api/v4/room"
  @token "slow12ab"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    user = insert(:user)
    insert(:profile, user: user)
    %{user: user}
  end

  test "records the room once when the provider takes its time to answer", %{user: user} do
    meeting = insert_meeting(user, insert_talk_integration(user))

    expect(HTTPClientMock, :request, fn :get, _list_url, _body, _headers, _opts ->
      ocs(200, [])
    end)

    # Exactly one creation: a second would fail the test as unexpected.
    expect(HTTPClientMock, :request, fn :post, @room_api, _body, _headers, _opts ->
      # A server that is slow to answer, not an error.
      receive do
      after
        100 -> ocs(201, %{"token" => @token})
      end
    end)

    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
    assert %MeetingSchema{video_room_id: @token} = Repo.get!(MeetingSchema, meeting.id)

    # A later run finds the room recorded and asks Nextcloud for nothing.
    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
    assert Repo.get!(MeetingSchema, meeting.id).video_room_id == @token
  end

  describe "creation_timeout_ms/1" do
    test "outlasts the budget of the meeting's own provider", %{user: user} do
      talk = insert_meeting(user, insert_talk_integration(user))
      teams = insert_meeting(user, insert(:video_integration, user: user, provider: "teams"))

      assert VideoRoomWorker.creation_timeout_ms(talk) >
               NextcloudTalkProvider.room_creation_budget_ms()

      assert VideoRoomWorker.creation_timeout_ms(teams) > TeamsProvider.room_creation_budget_ms()
    end

    test "waits only for the meeting's own provider, not for the slowest", %{user: user} do
      talk = insert_meeting(user, insert_talk_integration(user))

      assert VideoRoomWorker.creation_timeout_ms(talk) <
               ProviderRegistry.room_creation_budget_ms()
    end

    test "outlasts every provider when the meeting's integration cannot be resolved", %{
      user: user
    } do
      other_user = insert(:user)
      foreign = insert(:video_integration, user: other_user, provider: "nextcloud_talk")

      for meeting <- [
            %{organizer_user_id: user.id, video_integration_id: nil},
            %{organizer_user_id: nil, video_integration_id: foreign.id},
            %{organizer_user_id: user.id, video_integration_id: foreign.id}
          ] do
        assert Video.room_creation_budget_ms(
                 meeting.organizer_user_id,
                 meeting.video_integration_id
               ) ==
                 ProviderRegistry.room_creation_budget_ms()

        assert VideoRoomWorker.creation_timeout_ms(meeting) >
                 ProviderRegistry.room_creation_budget_ms()
      end
    end
  end

  defp insert_talk_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Nextcloud Talk",
      provider: "nextcloud_talk",
      base_url: @server,
      api_key_encrypted: nil,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
      provider_account_id: @server <> "||organiser"
    )
  end

  defp insert_meeting(user, integration) do
    start_time =
      DateTime.add(DateTime.utc_now(:second), System.unique_integer([:positive]), :hour)

    insert(:meeting,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: integration.id,
      video_room_id: nil
    )
  end

  defp ocs(status, data) do
    body = Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
    {:ok, %Req.Response{status: status, body: body}}
  end
end
