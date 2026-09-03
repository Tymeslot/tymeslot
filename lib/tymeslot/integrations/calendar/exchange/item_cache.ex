defmodule Tymeslot.Integrations.Calendar.Exchange.ItemCache do
  @moduledoc """
  Keeps the Exchange item cache — the `display_only` rows the dashboard grid
  renders — up to date from a folder's `SyncFolderItems` change feed.

  The incremental half of `Tymeslot.Workers.SyncExchangeCalendarWorker`'s item
  read, extracted from it because it is a different job with different state:
  the worker owns the cycle, its two halves and their outcomes, while this owns
  the per-folder tokens and what a feed's changes mean for cached rows. The
  worker still owns the full windowed read, because that read is also what
  runs when this one cannot.

  ## What a change means for the cache

  A `Create` or `Update` is an item to fetch, normalise and upsert. A `Delete`
  is a row to remove by `provider_event_id`. The third case has no counterpart
  in the feed at all: an item whose new dates put it **outside** the sync
  window is fetched like any other change and then deleted, because the feed
  cannot distinguish an item that moved away from one that was removed, and a
  cached row for an item no longer in the window is a row the grid would show
  in the wrong place.

  ## Tokens are per folder, and stored together

  `SyncFolderItems` is folder-scoped, so each selected folder keeps its own
  token, and they live together in `calendar_integrations.exchange_sync_states`
  keyed by folder id. Writes merge rather than replace, and prune the keys of
  folders no longer selected: a token left behind for a deselected folder would
  be replayed months later if that folder came back, against a feed the server
  has long since moved past.

  ## Nothing here decides freshness

  Whether a cycle may run incrementally at all is `full_sync_due?/1`'s answer
  and the worker's decision. This module never falls back to a full read on its
  own: a failure is reported, the tokens are left where they were, and the next
  cycle decides again with the same rule.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.ItemDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.ItemSync
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync

  # How stale the last full item read may get before one is forced. Daily: long
  # enough that the incremental path carries almost every cycle, short enough
  # that the sync window (a year each way) cannot slide past an item between
  # two full reads. It also bounds how long any drift between the cache and the
  # mailbox can persist, whatever caused it.
  @full_item_sync_after_seconds 24 * 60 * 60

  # No token for a folder means it has never been synced incrementally, so the
  # feed cannot say what changed and the whole window has to be read.
  @doc """
  States whether the item half must re-read its whole window this cycle.

  True when any selected folder has no state token, because a folder that has
  never been synced incrementally has no feed to ask; and true when the last
  full read is older than `@full_item_sync_after_seconds`, which is what picks
  up the items a sliding window has moved over (see the worker's moduledoc).
  """
  @spec full_sync_due?(CalendarIntegrationSchema.t()) :: boolean()
  def full_sync_due?(integration) do
    integration
    |> item_clients()
    |> Enum.any?(&is_nil(stored_sync_state(integration, &1)))
    |> Kernel.or(full_sync_stale?(integration))
  end

  defp full_sync_stale?(%{last_full_sync_at: nil}), do: true

  defp full_sync_stale?(%{last_full_sync_at: last}) do
    DateTime.diff(DateTime.utc_now(), last, :second) >= @full_item_sync_after_seconds
  end

  # Establishes a token for every folder that has none, so the next cycle can
  # go incremental. A folder that already has one is left alone; see the
  # moduledoc on why a full read does not refresh it.
  @doc """
  Gives every folder that has none a state token, so the next cycle can go
  incremental.

  Called after a full windowed read has already populated the cache, so the
  changes the feed reports here are discarded: the read has covered them. A
  folder that already has a token is left alone, and a folder whose bootstrap
  fails simply gets another full read next cycle.
  """
  @spec bootstrap_sync_states(CalendarIntegrationSchema.t()) :: :ok
  def bootstrap_sync_states(integration) do
    integration
    |> item_clients()
    |> Enum.reject(&stored_sync_state(integration, &1))
    |> Enum.reduce(%{}, fn client, acc ->
      case ItemSync.fetch_changes(client, folder_of(client), nil) do
        {:ok, %{sync_state: state}} when is_binary(state) ->
          Map.put(acc, folder_key(client), state)

        _unbootstrapped ->
          acc
      end
    end)
    |> persist_sync_states(integration)
  end

  # The incremental read. Each folder is asked what changed, and a folder with
  # nothing to say costs one `IdOnly` round trip and no cache write at all.
  @doc """
  Applies every folder's changes since its stored token, and answers the uids
  it touched.

  The first folder to fail ends the refresh with its error and no token is
  stored for any of them, so the retry re-reads the same span rather than
  acknowledging a partial one.
  """
  @spec incremental_refresh(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def incremental_refresh(integration, from, to) do
    integration
    |> item_clients()
    |> Enum.reduce_while({:ok, [], %{}}, fn client, {:ok, uids, states} ->
      case sync_one_folder(integration, client, from, to) do
        {:ok, folder_uids, nil} ->
          {:cont, {:ok, uids ++ folder_uids, states}}

        {:ok, folder_uids, state} ->
          {:cont, {:ok, uids ++ folder_uids, Map.put(states, folder_key(client), state)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> finish_incremental(integration)
  end

  # The token is persisted only once every folder has succeeded. Storing one
  # for a folder that synced while a later folder failed would have the failed
  # run's successes acknowledged and the retry skip them.
  defp finish_incremental({:ok, uids, states}, integration) do
    persist_sync_states(states, integration)
    {:ok, uids}
  end

  defp finish_incremental({:error, _reason} = error, _integration), do: error

  defp sync_one_folder(integration, client, from, to) do
    stored = stored_sync_state(integration, client)

    with {:ok, changes} <- ItemSync.fetch_changes(client, folder_of(client), stored) do
      apply_changes(integration, client, changes, from, to)
    end
  end

  # A feed that reports nothing still advances the token: the server may have
  # rewritten it even with no changes behind it, and replaying a superseded one
  # costs a redundant page next cycle.
  defp apply_changes(
         _integration,
         _client,
         %{created: [], updated: [], deleted: []} = changes,
         _from,
         _to
       ) do
    {:ok, [], changes.sync_state}
  end

  defp apply_changes(integration, client, changes, from, to) do
    with {:ok, items} <- ItemDiscovery.fetch_items(client, changes.created ++ changes.updated),
         {:ok, events} <- Provider.normalise_events(items, item_context(integration, client)) do
      {in_window, out_of_window} = Enum.split_with(events, &in_window?(&1, from, to))

      # An item the feed reported but the batch could not return is neither
      # kept nor deleted: `require_readable_batch/1` has already refused a
      # wholly unreadable batch, and a partly unreadable one logs the codes.
      # Deleting on a read failure would empty the grid over a transient one.
      write_incremental(integration, in_window, changes.deleted ++ provider_ids(out_of_window))

      {:ok, Enum.map(in_window, & &1.uid), changes.sync_state}
    end
  end

  # Upsert then delete, in that order and both by `provider_event_id`. An item
  # that moved out of the window appears in both lists otherwise — it was
  # fetched, normalised and then classified out — and deleting last is what
  # makes the outcome the same either way.
  defp write_incremental(integration, events, deleted_ids) do
    Sync.upsert_cache(integration, events)

    ProviderCalendarEventQueries.delete_by_provider_event_ids(
      integration.id,
      Enum.uniq(deleted_ids)
    )
  end

  defp provider_ids(events), do: Enum.map(events, & &1.provider_event_id)

  # The same overlap test the cache query applies, so an event is kept here
  # exactly when a windowed read would have returned it. All-day events carry
  # dates rather than instants, and `to_read_path_map/1` is what already knows
  # how to compare the two.
  defp in_window?(event, from, to) do
    overlaps?(event.start_at || event.start_date, event.end_at || event.end_date, from, to)
  end

  defp overlaps?(nil, _end_at, _from, _to), do: false
  defp overlaps?(_start_at, nil, _from, _to), do: false

  defp overlaps?(start_at, end_at, from, to) do
    compare(start_at, to) != :gt and compare(end_at, from) != :lt
  end

  defp compare(%Date{} = date, %DateTime{} = boundary),
    do: Date.compare(date, DateTime.to_date(boundary))

  defp compare(%DateTime{} = datetime, %DateTime{} = boundary),
    do: DateTime.compare(datetime, boundary)

  @doc """
  The per-folder normalisation context both item reads share.

  Public because the worker's full read needs the identical context: the
  `provider_calendar_id` a row is cached under has to be the same string
  whichever path wrote it, or the two paths would cache the same folder twice
  under different ids.
  """
  @spec item_context(CalendarIntegrationSchema.t(), map()) :: EventNormaliser.context()
  def item_context(integration, client) do
    %{
      calendar_integration_id: integration.id,
      provider_calendar_id: folder_key(client),
      synced_at: DateTime.utc_now()
    }
  end

  defp item_clients(integration), do: Provider.item_client_configs(integration)

  defp folder_of(client), do: client[:calendar_id] || :calendar

  defp folder_key(client), do: to_string(folder_of(client))

  defp stored_sync_state(integration, client) do
    integration.exchange_sync_states
    |> Kernel.||(%{})
    |> Map.get(folder_key(client))
  end

  # Merged onto what is stored rather than replacing it, so a cycle that
  # touched one folder does not drop another's token. Keys for folders the
  # owner has since deselected are pruned in the same write: left behind, they
  # would silently resurrect a stale token if that folder were reselected
  # months later.
  defp persist_sync_states(states, _integration) when map_size(states) == 0, do: :ok

  defp persist_sync_states(states, integration) do
    live_keys = integration |> item_clients() |> Enum.map(&folder_key/1) |> MapSet.new()

    merged =
      integration.exchange_sync_states
      |> Kernel.||(%{})
      |> Map.merge(states)
      |> Map.filter(fn {key, _state} -> MapSet.member?(live_keys, key) end)

    case CalendarIntegrationQueries.update_sync_state(integration, %{
           exchange_sync_states: merged
         }) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        # Not fatal: the tokens are an optimisation, and losing them costs the
        # next cycle a full read rather than correctness.
        Logger.warning("Failed to persist Exchange sync states",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end
end
