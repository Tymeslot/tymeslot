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

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Oban.Cron.Expression
  alias Tymeslot.Workers.ExpiredVideoRoomCleanupWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @day 86_400

  setup do
    with_config(:tymeslot, :video_room_retention_days, 7)
    %{user: create_user_with_profile().user}
  end

  test "deletes a Talk room once its meeting ended more than the retention period ago", %{
    user: user
  } do
    due = insert_ended(user, 8, "nextcloud_talk", "due00001")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    assert_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => due.id, "action" => "delete"}
    )
  end

  test "keeps a Talk room whose meeting ended within the retention period", %{user: user} do
    recent = insert_ended(user, 6, "nextcloud_talk", "recent01")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => recent.id, "action" => "delete"}
    )
  end

  test "honours a configured retention period", %{user: user} do
    with_config(:tymeslot, :video_room_retention_days, 3)
    due = insert_ended(user, 4, "nextcloud_talk", "due00002")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    assert_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => due.id, "action" => "delete"}
    )
  end

  test "leaves the rooms of providers that need no clean-up", %{user: user} do
    zoom = insert_ended(user, 8, "zoom", "86360699337")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => zoom.id, "action" => "delete"}
    )
  end

  test "ignores a meeting whose room is already gone", %{user: user} do
    cleaned = insert_ended(user, 8, "nextcloud_talk", nil)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => cleaned.id, "action" => "delete"}
    )
  end

  test "gives up on a room still out of reach a month after it fell due", %{user: user} do
    stale = insert_ended(user, 40, "nextcloud_talk", "stale001")

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_enqueued(
      worker: VideoSyncWorker,
      args: %{"meeting_id" => stale.id, "action" => "delete"}
    )
  end

  # The production crontab is only assembled in runtime.exs and never loaded in
  # test, so a typo in the schedule or the module name would otherwise ship
  # silently and leave every conversation in place.
  for file <- ["dev.exs", "runtime.exs"] do
    test "is scheduled in the #{file} crontab with a schedule Oban can parse" do
      config =
        [__DIR__, "..", "..", "..", "config", unquote(file)]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      pattern = ~r/\{\s*"([^"]+)"\s*,\s*Tymeslot\.Workers\.ExpiredVideoRoomCleanupWorker\s*\}/

      assert [_match, schedule] = Regex.run(pattern, config)
      assert {:ok, _expression} = Expression.parse(schedule)
    end
  end

  defp insert_ended(user, ended_days_ago, provider, room_id) do
    insert_meeting_for_user(user, %{
      start_offset: -(ended_days_ago * @day) - 1800,
      duration: 1800,
      video_provider: provider,
      video_room_id: room_id
    })
  end
end
