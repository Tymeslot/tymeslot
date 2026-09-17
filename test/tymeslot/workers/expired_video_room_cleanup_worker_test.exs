defmodule Tymeslot.Workers.ExpiredVideoRoomCleanupWorkerTest do
  @moduledoc """
  Drives the daily scan that deletes the video rooms of meetings that ended
  more than the retention period ago, for providers whose rooms otherwise stay
  on the organiser's server.
  """

  # Not async: the tests change application config the worker reads.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Oban.Cron.Expression
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.ExpiredVideoRoomCleanupWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @day 86_400

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :video_room_retention_days, 7)
    %{user: create_user_with_profile().user}
  end

  test "deletes a Talk room once its meeting ended more than the retention period ago", %{
    user: user
  } do
    due = insert_ended(user, 8, "nextcloud_talk", "due00001")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    assert_delete_enqueued(due)
  end

  test "keeps a Talk room whose meeting ended within the retention period", %{user: user} do
    recent = insert_ended(user, 6, "nextcloud_talk", "recent01")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(recent)
  end

  test "honours a configured retention period", %{user: user} do
    with_config(:tymeslot, :video_room_retention_days, 3)
    due = insert_ended(user, 4, "nextcloud_talk", "due00002")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    assert_delete_enqueued(due)
  end

  test "leaves the rooms of providers that need no clean-up", %{user: user} do
    zoom = insert_ended(user, 8, "zoom", "86360699337")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(zoom)
  end

  test "ignores a meeting whose room is already gone", %{user: user} do
    cleaned = insert_ended(user, 8, "nextcloud_talk", nil)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(cleaned)
  end

  test "gives up on a room still out of reach a month after it fell due", %{user: user} do
    stale = insert_ended(user, 40, "nextcloud_talk", "stale001")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(stale)
  end

  # The orphaned room scan owns cancelled meetings, so the two scans never both
  # queue the same room.
  test "leaves cancelled meetings to the orphaned room scan", %{user: user} do
    cancelled = insert_ended(user, 8, "nextcloud_talk", "cancel01", status: "cancelled")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(cancelled)
  end

  test "deletes a room its own healthy integration can still reach", %{user: user} do
    integration = insert_talk_integration(user, "healthy.example.com")

    due =
      insert_ended(user, 8, "nextcloud_talk", "healthy1", video_integration_id: integration.id)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    assert_delete_enqueued(due)
  end

  # The provider refuses locally while the integration awaits reconnection, so
  # queueing its rooms would only log a refusal every night for a month.
  test "skips rooms whose integration is waiting to be reconnected", %{user: user} do
    integration = insert_talk_integration(user, "flagged.example.com", needs_reauth: true)

    flagged =
      insert_ended(user, 8, "nextcloud_talk", "flagged1", video_integration_id: integration.id)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(flagged)
  end

  # The disconnect worker is already deleting this integration's rooms, and
  # every delete queued here would be refused against a row about to go.
  test "skips rooms whose integration is being disconnected", %{user: user} do
    integration =
      insert_talk_integration(user, "leaving.example.com", deleted_at: DateTime.utc_now(:second))

    leaving =
      insert_ended(user, 8, "nextcloud_talk", "leaving1", video_integration_id: integration.id)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_delete_enqueued(leaving)
  end

  test "a deleted conversation is cleared and not queued again the next night", %{user: user} do
    host = "journey.example.com"
    integration = insert_talk_integration(user, host)

    due =
      insert_ended(user, 8, "nextcloud_talk", "journey1", video_integration_id: integration.id)

    expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://#{host}/ocs/v2.php/apps/spreed/api/v4/room/journey1"
      {:ok, %Req.Response{status: 200, body: ocs(nil)}}
    end)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)

    assert Repo.reload!(due).video_room_id == nil

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
    refute_enqueued(worker: VideoSyncWorker)
  end

  # The production crontab is only assembled in runtime.exs and never loaded in
  # test, so a typo in the schedule or the module name would otherwise ship
  # silently and leave every conversation in place. The pattern is anchored to
  # the start of a line so a commented-out entry does not count.
  for file <- ["dev.exs", "runtime.exs"] do
    test "is scheduled in the #{file} crontab with a schedule Oban can parse" do
      config =
        [__DIR__, "..", "..", "..", "config", unquote(file)]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      pattern =
        ~r/^\s*\{\s*"([^"]+)"\s*,\s*Tymeslot\.Workers\.ExpiredVideoRoomCleanupWorker\s*\}/m

      assert [_match, schedule] = Regex.run(pattern, config)
      assert {:ok, _expression} = Expression.parse(schedule)
    end
  end

  defp assert_delete_enqueued(meeting),
    do: assert_enqueued(worker: VideoSyncWorker, args: delete_args(meeting))

  defp refute_delete_enqueued(meeting),
    do: refute_enqueued(worker: VideoSyncWorker, args: delete_args(meeting))

  defp delete_args(meeting), do: %{"meeting_id" => meeting.id, "action" => "delete"}

  defp insert_ended(user, ended_days_ago, provider, room_id, attrs \\ []) do
    insert_meeting_for_user(
      user,
      Map.merge(
        %{
          start_offset: -(ended_days_ago * @day) - 1800,
          duration: 1800,
          video_provider: provider,
          video_room_id: room_id
        },
        Map.new(attrs)
      )
    )
  end

  # Each test gets its own server, so no test's calls reach another test's
  # per-host circuit breaker.
  defp insert_talk_integration(user, host, attrs \\ []) do
    base_url = "https://" <> host

    insert(
      :video_integration,
      [
        user: user,
        provider: "nextcloud_talk",
        base_url: base_url,
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: base_url <> "||organiser"
      ] ++ attrs
    )
  end

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
