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
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
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

  describe "rooms made for calendar grid events" do
    # A grid event lives only in the organiser's calendar, so no meeting holds
    # its conversation: the grid records it when the event is created.
    test "a conversation made with a grid event is deleted once the event is past retention", %{
      user: user
    } do
      host = "grid-journey.example.com"
      talk = insert_talk_integration(user, host)
      calendar = insert(:calendar_integration, user: user, is_active: true)

      # Plays the organiser's Nextcloud server: no conversation exists until
      # one is created, and every delete it receives reaches the test.
      test = self()
      rooms_url = "https://#{host}/ocs/v2.php/apps/spreed/api/v4/room"

      stub(HTTPClientMock, :request, fn
        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: ocs([])}}

        :post, ^rooms_url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 201, body: ocs(%{"token" => "grid0001"})}}

        :delete, url, _body, _headers, _opts ->
          send(test, {:deleted, url})
          {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, "grid-journey-uid"}
      end)

      start_at = DateTime.add(DateTime.utc_now(:second), -8 * @day - 3600, :second)

      assert {:ok, %{video_room_id: "grid0001"}} =
               EventCreation.run_create_event(%{
                 creating: %{
                   title: "Planning",
                   integration_id: calendar.id,
                   calendar_id: "primary",
                   attendees: [],
                   video_integration_id: talk.id
                 },
                 user_id: user.id,
                 start_at: start_at,
                 end_at: DateTime.add(start_at, 1800, :second)
               })

      assert [%EventVideoRoomSchema{id: room_id, room_id: "grid0001"}] =
               Repo.all(EventVideoRoomSchema)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
      assert_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room_id))

      refute_received {:deleted, _url}

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
      assert_received {:deleted, url}
      assert url == rooms_url <> "/grid0001"
      assert Repo.get(EventVideoRoomSchema, room_id) == nil

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "keeps a grid event's conversation within the retention period", %{user: user} do
      room = insert_event_room(user, insert_talk_integration(user, "grid-recent.example.com"), 6)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

      refute_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room.id))
    end

    test "gives up on a grid event's conversation a month after it fell due", %{user: user} do
      room = insert_event_room(user, insert_talk_integration(user, "grid-stale.example.com"), 40)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

      refute_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room.id))
    end

    test "never deletes the conversation of a series with no end", %{user: user} do
      talk = insert_talk_integration(user, "grid-series.example.com")
      room = insert_event_room(user, talk, 8, ends_at: nil)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

      refute_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room.id))
    end

    test "skips a grid event's conversation whose integration is waiting to be reconnected", %{
      user: user
    } do
      talk = insert_talk_integration(user, "grid-flagged.example.com", needs_reauth: true)
      room = insert_event_room(user, talk, 8)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

      refute_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room.id))
    end

    test "skips a grid event's conversation whose integration is being disconnected", %{
      user: user
    } do
      talk =
        insert_talk_integration(user, "grid-leaving.example.com",
          deleted_at: DateTime.utc_now(:second)
        )

      room = insert_event_room(user, talk, 8)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

      refute_enqueued(worker: VideoSyncWorker, args: event_room_delete_args(room.id))
    end
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

  defp event_room_delete_args(room_id), do: %{"event_room_id" => room_id, "action" => "delete"}

  defp insert_event_room(user, integration, ended_days_ago, attrs \\ []) do
    ends_at = DateTime.add(DateTime.utc_now(:second), -ended_days_ago * @day, :second)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: user.id,
            video_integration_id: integration.id,
            calendar_integration_id: insert(:calendar_integration, user: user).id,
            event_uid: "grid-" <> Integer.to_string(System.unique_integer([:positive])),
            room_id: "room" <> Integer.to_string(ended_days_ago),
            starts_at: DateTime.add(ends_at, -1800, :second),
            ends_at: ends_at
          },
          Map.new(attrs)
        )
      )

    room
  end

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
