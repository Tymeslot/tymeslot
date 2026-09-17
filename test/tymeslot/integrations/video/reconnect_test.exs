defmodule Tymeslot.Integrations.Video.ReconnectTest do
  @moduledoc """
  A proven reconnect catches the integration's rooms up on the changes they
  missed while it needed reconnecting: live bookings' rooms are updated,
  released bookings' rooms deleted, and only when the row was flagged and its
  provider keeps the booking's time on the room.
  """

  # Not async: one test asserts on a log line, and a `:logger` handler is
  # global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :video

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Video.Reconnect
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.VideoSyncWorker

  setup do
    %{user: insert(:user)}
  end

  test "queues an update for live bookings and a delete for released ones", %{user: user} do
    integration = insert(:video_integration, user: user, provider: "zoom", needs_reauth: true)

    live = room(integration, 1)
    pending = room(integration, 2, status: "pending")
    cancelled = room(integration, 3, status: "cancelled")
    expired = room(integration, 4, status: "expired")
    room(integration, -3)

    assert {:ok, updated} = Reconnect.save(integration, %{access_token: "new-token"})

    refute updated.needs_reauth
    assert queued("update") == Enum.sort([live.id, pending.id])
    assert queued("delete") == Enum.sort([cancelled.id, expired.id])
  end

  test "queues nothing for an integration that was not flagged", %{user: user} do
    integration = insert(:video_integration, user: user, provider: "zoom")
    room(integration, 1)

    assert {:ok, _updated} = Reconnect.save(integration, %{access_token: "new-token"})

    refute_enqueued(worker: VideoSyncWorker)
  end

  test "queues nothing for a provider whose rooms are only links", %{user: user} do
    integration =
      insert(:video_integration, user: user, provider: "google_meet", needs_reauth: true)

    room(integration, 1)

    assert {:ok, updated} = Reconnect.save(integration, %{access_token: "new-token"})

    refute updated.needs_reauth
    refute_enqueued(worker: VideoSyncWorker)
  end

  test "catches up a row flagged after the integration was read", %{user: user} do
    integration = insert(:video_integration, user: user, provider: "nextcloud_talk")
    meeting = room(integration, 1)
    Repo.update!(Changeset.change(Repo.reload!(integration), needs_reauth: true))

    assert {:ok, _updated} = Reconnect.save(integration, %{client_secret: "New-App-Password"})

    refute Repo.reload!(integration).needs_reauth
    assert queued("update") == [meeting.id]
  end

  test "queues nothing when the write is refused", %{user: user} do
    integration = insert(:video_integration, user: user, provider: "zoom", needs_reauth: true)
    room(integration, 1)

    assert {:error, %Changeset{}} = Reconnect.save(integration, %{name: nil})

    refute_enqueued(worker: VideoSyncWorker)
    assert Repo.reload!(integration).needs_reauth
  end

  test "says so when it catches up only the first rooms", %{user: user} do
    LogCapture.attach()
    integration = insert(:video_integration, user: user, provider: "zoom", needs_reauth: true)
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      MeetingSchema,
      for minutes <- 1..501 do
        start_time = DateTime.add(now, minutes, :hour)

        :meeting
        |> build(
          organizer_user_id: user.id,
          video_integration_id: integration.id,
          video_room_id: "room-#{minutes}",
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          inserted_at: now,
          updated_at: now
        )
        |> Map.take(MeetingSchema.__schema__(:fields))
        |> Map.delete(:id)
      end
    )

    assert {:ok, _updated} = Reconnect.save(integration, %{access_token: "new-token"})

    event = LogCapture.await_log("caught up only the first rooms")
    assert %{integration_id: id, limit: 500} = LogCapture.user_metadata(event)
    assert id == integration.id
    assert length(all_enqueued(worker: VideoSyncWorker)) == 500
  end

  # A meeting holding one of `integration`'s rooms, starting `offset_days` from
  # now.
  defp room(integration, offset_days, overrides \\ []) do
    start_time = DateTime.add(DateTime.utc_now(:second), offset_days, :day)

    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: integration.user_id,
          video_integration_id: integration.id,
          video_provider: integration.provider,
          video_room_id: "room-#{System.unique_integer([:positive])}",
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        ],
        overrides
      )
    )
  end

  defp queued(action) do
    [worker: VideoSyncWorker, args: %{"action" => action}]
    |> all_enqueued()
    |> Enum.map(& &1.args["meeting_id"])
    |> Enum.sort()
  end
end
