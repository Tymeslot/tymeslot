defmodule Tymeslot.Integrations.Calendar.IntegrationCacheLockTest do
  @moduledoc """
  A sync writing an integration's cached events, raced against the deletions
  that reach those rows from a parent: of the calendar integration, of the
  whole account, and of a video integration a cached row names. Each runs on
  its own connection through `Tymeslot.Test.RaceConductor` (see its moduledoc
  for why the module is synchronous and why `on_exit` deletes what it
  committed).

  The sync is staged as a transaction that has already written one cached row
  when the deletion starts, then writes another: the shape of the CalDAV
  reconciler's upsert-then-delete. Without the integration cache lock it
  holds that row while the deletion holds the parent and waits for the row,
  and its next write then waits for the parent: Postgres breaks the deadlock
  by aborting one side. With the lock, whichever comes second waits for the
  first to commit, and both succeed.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @start ~U[2026-11-02 10:00:00Z]

  setup do
    {user, integration, video} =
      unboxed(fn ->
        user = insert(:user)
        integration = insert(:calendar_integration, user: user, provider: "google")
        video = insert(:video_integration, user: user)
        {user, integration, video}
      end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id)) end)
    end)

    %{user: user, integration: integration, video: video, relay: relay()}
  end

  defp event(integration, uid, attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: uid,
          calendar_integration_id: integration.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: uid,
          synced_at: DateTime.utc_now(),
          all_day: false,
          start_at: @start,
          end_at: DateTime.add(@start, 3600, :second)
        },
        attrs
      )
    )
  end

  defp cache(integration, uid, attrs) do
    unboxed(fn ->
      insert(
        :provider_calendar_event,
        Keyword.merge(
          [
            calendar_integration: integration,
            uid: uid,
            provider_event_id: uid,
            start_at: @start,
            end_at: DateTime.add(@start, 3600, :second)
          ],
          attrs
        )
      )
    end)
  end

  # A sync transaction that rewrites `held` (a row already cached, which it
  # then holds), tells `relay` it holds it, parks, and writes `then`.
  defp sync(integration, held, then, relay) do
    fn hold ->
      Repo.transaction(fn ->
        {:ok, 1} = Sync.upsert_cache(integration, [held])
        send(relay, :sync_holds)
        hold.(nil)
        {:ok, _count} = Sync.upsert_cache(integration, then)
        :synced
      end)
    end
  end

  # A deletion that starts only once the sync holds its row, so it always
  # meets the sync mid-transaction rather than racing it to the start.
  defp after_sync_holds(relay, delete) do
    fn _hold ->
      send(relay, {:deleter, self()})

      receive do
        :go -> delete.()
      end
    end
  end

  # Passes the sync's word on to the deletion, whichever reaches it first.
  defp relay do
    spawn_link(fn ->
      receive do
        :sync_holds -> :ok
      end

      receive do
        {:deleter, pid} -> send(pid, :go)
      end
    end)
  end

  defp refute_deadlock(results) do
    for result <- results, do: refute(match?({:raised, _error}, result), inspect(result))
  end

  defp cached_uids(integration) do
    unboxed(fn ->
      Repo.all(
        from(e in ProviderCalendarEventSchema,
          where: e.calendar_integration_id == ^integration.id,
          select: e.uid
        )
      )
    end)
  end

  test "deleting the calendar integration mid-sync waits for the sync, then removes its rows",
       %{user: user, integration: integration, relay: relay} do
    cache(integration, "standup", [])

    [synced, deleted] =
      race([
        sync(integration, event(integration, "standup"), [event(integration, "review")], relay),
        after_sync_holds(relay, fn ->
          Deletion.delete_with_primary_reassignment(user.id, integration.id)
        end)
      ])

    refute_deadlock([synced, deleted])
    assert {:ok, :synced} = synced
    assert {:ok, _deleted} = deleted
    assert cached_uids(integration) == []
  end

  test "deleting the account mid-sync waits for the sync, then removes everything",
       %{user: user, integration: integration, relay: relay} do
    cache(integration, "standup", [])

    [synced, deleted] =
      race([
        sync(integration, event(integration, "standup"), [event(integration, "review")], relay),
        after_sync_holds(relay, fn -> AccountDeletion.delete_account(user) end)
      ])

    refute_deadlock([synced, deleted])
    assert {:ok, :synced} = synced
    assert {:ok, _user} = deleted
    refute unboxed(fn -> Repo.get(CalendarIntegrationSchema, integration.id) end)
  end

  # The sync hands a replaced series master's room to the occurrence it
  # caches, which names the video integration the deletion is removing.
  test "deleting a video integration a cached row names mid-sync waits for the sync",
       %{integration: integration, video: video, relay: relay} do
    cache(integration, "weekly-master",
      provider_event_id: "weekly",
      video_integration_id: video.id,
      video_link: "https://meet.example.com/weekly"
    )

    occurrence =
      event(integration, "weekly-occurrence", %{
        provider_event_id: "weekly_20261102",
        recurring_event_id: "weekly"
      })

    [synced, deleted] =
      race([
        sync(
          integration,
          event(integration, "weekly-master", %{provider_event_id: "weekly"}),
          [occurrence],
          relay
        ),
        after_sync_holds(relay, fn ->
          VideoIntegrationQueries.delete(Repo.get!(VideoIntegrationSchema, video.id))
        end)
      ])

    refute_deadlock([synced, deleted])
    assert {:ok, :synced} = synced
    assert {:ok, _video} = deleted
  end

  test "a cache write whose integration is gone writes nothing", %{integration: integration} do
    unboxed(fn -> Repo.delete!(Repo.get!(CalendarIntegrationSchema, integration.id)) end)

    attrs =
      integration
      |> event("written-after-delete")
      |> ProviderCalendarEventSchema.from_calendar_event()

    assert {:error, :integration_gone} =
             unboxed(fn ->
               IntegrationCacheQueries.replace_cached_rows(integration.id, :all, [attrs])
             end)

    assert cached_uids(integration) == []
  end
end
