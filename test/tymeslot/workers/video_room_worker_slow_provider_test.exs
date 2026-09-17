defmodule Tymeslot.Workers.VideoRoomWorkerSlowProviderTest do
  @moduledoc """
  A provider that answers slowly still gets its room recorded.

  The room job used to stop waiting after 20 seconds, although a provider's
  own request timeouts allow longer. A room the provider made in that gap was
  abandoned, and the retry made a second one. The job now waits for longer
  than the slowest provider's declared network budget, which this proves
  against a Nextcloud server that answers only after the old timeout.
  """

  # Not async: the job calls the provider from a supervised task, and the Talk
  # circuit breakers are VM-wide. The test waits past the old 20 second
  # timeout, so it gets a longer timeout of its own.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video
  @moduletag timeout: 60_000

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoRoomWorker

  @server "https://slow.talk.example.com"
  @room_api @server <> "/ocs/v2.php/apps/spreed/api/v4/room"
  @token "slow12ab"
  @old_timeout_ms 20_000

  setup :set_mox_global
  setup :verify_on_exit!

  test "records the room once when the provider answers after the old timeout" do
    user = insert(:user)
    insert(:profile, user: user)

    integration =
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

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        video_integration_id: integration.id,
        video_room_id: nil
      )

    test = self()

    expect(HTTPClientMock, :request, fn :get, _list_url, _body, _headers, _opts ->
      ocs(200, [])
    end)

    # The server holds its answer until the test releases it. Exactly one
    # creation is expected: a second would fail the test as unexpected.
    expect(HTTPClientMock, :request, fn :post, @room_api, _body, _headers, _opts ->
      send(test, {:creating, self()})

      receive do
        :answer -> ocs(201, %{"token" => @token})
      end
    end)

    job = Task.async(fn -> perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id}) end)

    assert_receive {:creating, server}, 5_000

    # Past the moment the old timeout would have abandoned the call, the job is
    # still waiting for the server.
    assert Task.yield(job, @old_timeout_ms + 1_000) == nil

    send(server, :answer)
    assert {:ok, :ok} = Task.yield(job, 5_000)

    assert %MeetingSchema{video_room_id: @token} = Repo.get!(MeetingSchema, meeting.id)

    # A later run finds the room recorded and asks Nextcloud for nothing.
    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
    assert Repo.get!(MeetingSchema, meeting.id).video_room_id == @token
  end

  test "waits longer than the slowest provider's declared network budget" do
    budget = ProviderRegistry.room_creation_budget_ms()

    assert budget > @old_timeout_ms
    assert VideoRoomWorker.creation_timeout_ms() > budget
  end

  defp ocs(status, data) do
    body = Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
    {:ok, %Req.Response{status: status, body: body}}
  end
end
