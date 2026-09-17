defmodule Tymeslot.Workers.VideoRoomWorkerRoomCreationErrorTest do
  @moduledoc """
  A server that refuses to create rooms for a reason no retry fixes.

  The room job announces the booking without a link and stops, and the refusal
  is recorded on the integration with its code and emailed to the owner once,
  however many bookings meet it. The credentials work, so the integration is
  never flagged for reconnection. The next room the integration creates clears
  the record.
  """

  # Not async: the job calls the provider from a supervised task, which needs
  # the global Mox mode, and the Talk circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  @room_api "/ocs/v2.php/apps/spreed/api/v4/room"
  @restricted ~s({"ocs":{"meta":{"status":"failure","statuscode":403,"message":""},"data":{"error":"permissions"}}})
  @password_required ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"password","message":"Password needs to be set"}}})

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()
    :ok
  end

  test "two bookings refused at once record the refusal and queue one email" do
    %{integration: integration, server: server} = talk_integration("restricted")
    meetings = for _booking <- 1..2, do: meeting(integration)

    # The two jobs' requests interleave, so each is answered by its method.
    expect(HTTPClientMock, :request, 4, fn
      :get, url, _body, _headers, _opts ->
        assert String.starts_with?(url, server <> @room_api <> "?")
        {:ok, %Req.Response{status: 200, body: ocs([])}}

      :post, url, _body, _headers, _opts ->
        assert url == server <> @room_api
        {:ok, %Req.Response{status: 403, body: @restricted}}
    end)

    results =
      meetings
      |> Enum.map(fn meeting ->
        Task.async(fn -> perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id}) end)
      end)
      |> Task.await_many(30_000)

    # Discarded, not retried: the server would refuse every attempt the same way.
    assert results == [{:discard, "Invalid configuration"}, {:discard, "Invalid configuration"}]

    stored = Repo.get!(VideoIntegrationSchema, integration.id)

    assert %{
             room_creation_error: :conversation_creation_restricted,
             room_creation_errors_notified: [:conversation_creation_restricted],
             needs_reauth: false
           } = stored

    assert %DateTime{} = stored.room_creation_error_since
    assert Enum.all?(meetings, &is_nil(Repo.reload!(&1).video_room_id))

    assert [%{args: args}] = refusal_emails()

    assert args == %{
             "action" => "send_video_room_creation_error_notification",
             "user_id" => integration.user_id,
             "integration_id" => integration.id,
             "error_code" => "conversation_creation_restricted"
           }
  end

  test "a refusal seen again keeps the time it was first seen and queues no second email" do
    %{integration: integration, server: server} = talk_integration("again")

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    first_seen = ~U[2026-01-01 00:00:00Z]

    integration
    |> Changeset.change(room_creation_error_since: first_seen)
    |> Repo.update!()

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    assert %{room_creation_error_since: ^first_seen} =
             Repo.get!(VideoIntegrationSchema, integration.id)

    assert length(refusal_emails()) == 1
  end

  test "a different refusal replaces the recorded one and is emailed about too" do
    %{integration: integration, server: server} = talk_integration("changed")

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 400, @password_required)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    assert %{room_creation_error: :password_required} =
             Repo.get!(VideoIntegrationSchema, integration.id)

    assert refusal_emails() |> Enum.map(& &1.args["error_code"]) |> Enum.sort() ==
             ["conversation_creation_restricted", "password_required"]
  end

  test "the next room created clears the refusal, and its return emails nobody again" do
    %{integration: integration, server: server} = talk_integration("cleared")

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 201, ocs(%{"token" => "made12ab"}))
    booked = meeting(integration)
    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => booked.id})

    assert Repo.reload!(booked).video_room_id == "made12ab"

    assert %{room_creation_error: nil, room_creation_error_since: nil} =
             Repo.get!(VideoIntegrationSchema, integration.id)

    # The same restriction switched on again is shown again, but the owner was
    # already emailed about it once.
    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    assert %{room_creation_error: :conversation_creation_restricted} =
             Repo.get!(VideoIntegrationSchema, integration.id)

    assert length(refusal_emails()) == 1
  end

  test "a failure that says nothing about the server's settings leaves the record alone" do
    %{integration: integration, server: server} = talk_integration("outage")

    answer(:get, server, 200, ocs([]))
    answer(:post, server, 403, @restricted)
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    answer(:get, server, 503, "")
    perform_job(VideoRoomWorker, %{"meeting_id" => meeting(integration).id})

    assert %{room_creation_error: :conversation_creation_restricted} =
             Repo.get!(VideoIntegrationSchema, integration.id)
  end

  defp refusal_emails do
    all_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_video_room_creation_error_notification"}
    )
  end

  defp answer(method, server, status, body) do
    url =
      server <>
        @room_api <> if(method == :get, do: "?noStatusUpdate=1&includeLastMessage=0", else: "")

    expect(HTTPClientMock, :request, fn ^method, ^url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: body}}
    end)
  end

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})

  # Each test gets its own server, so no test's calls reach another test's
  # per-host circuit breaker.
  defp talk_integration(name) do
    server = "https://#{name}.refusals.example.com"
    user = insert(:user)
    insert(:profile, user: user)

    integration =
      insert(:video_integration,
        user: user,
        name: "Nextcloud Talk",
        provider: "nextcloud_talk",
        base_url: server,
        api_key_encrypted: nil,
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: server <> "||organiser"
      )

    %{integration: integration, server: server}
  end

  defp meeting(integration) do
    user = Repo.preload(integration, :user).user

    # Each booking at its own hour, as an organiser holds one booking a slot.
    start_time =
      DateTime.utc_now(:second)
      |> DateTime.add(3, :day)
      |> DateTime.add(System.unique_integer([:positive]), :hour)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: integration.id,
      video_room_id: nil,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    )
  end
end
