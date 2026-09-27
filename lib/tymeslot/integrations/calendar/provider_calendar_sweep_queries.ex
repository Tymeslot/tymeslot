defmodule Tymeslot.Integrations.Calendar.ProviderCalendarSweepQueries do
  @moduledoc """
  Database queries for sweeping the cached rows of one calendar that a
  complete listing of it no longer returned
  (`Tymeslot.Integrations.Calendar.Google.CacheSweep`).

  A row is a candidate only while nothing has written it since the listing
  began, and while it holds no local change still waiting for the server.
  "Written" is read from `updated_at`, which every write to the table
  stamps: the sync's upsert (`upsert_batch/1` sets it along with
  `synced_at`), and the calendar grid's creates and edits, which leave
  `synced_at` as the last sync set it. Both conditions are checked again by
  the delete itself, so a row written between reading the candidates and
  deleting them is kept.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @synced "synced"

  @typedoc "What a sweep needs to know about a candidate row."
  @type candidate :: %{id: integer(), uid: String.t(), provider_event_id: String.t() | nil}

  @doc """
  The rows of the integration `calendar_integration_id` filed under
  `provider_calendar_id` that overlap `range_start`..`range_end` (with the
  overlap `ProviderCalendarEventQueries.where_overlapping_range/3` applies)
  and have not been written since `unwritten_since`.
  """
  @spec list_candidates(integer(), String.t(), DateTime.t(), DateTime.t(), DateTime.t()) ::
          [candidate()]
  def list_candidates(
        calendar_integration_id,
        provider_calendar_id,
        range_start,
        range_end,
        unwritten_since
      ) do
    ProviderCalendarEventSchema
    |> where_sweepable(calendar_integration_id, provider_calendar_id, unwritten_since)
    |> ProviderCalendarEventQueries.where_overlapping_range(range_start, range_end)
    |> select([e], %{id: e.id, uid: e.uid, provider_event_id: e.provider_event_id})
    |> Repo.all()
  end

  @doc """
  Deletes the rows `ids` of the integration filed under
  `provider_calendar_id` that are still unwritten since `unwritten_since`.
  Returns the uids of the rows deleted.
  """
  @spec delete_candidates(integer(), String.t(), [integer()], DateTime.t()) :: [String.t()]
  def delete_candidates(_calendar_integration_id, _provider_calendar_id, [], _unwritten_since),
    do: []

  def delete_candidates(calendar_integration_id, provider_calendar_id, ids, unwritten_since) do
    ids
    |> Enum.chunk_every(1000)
    |> Enum.flat_map(fn chunk ->
      {_count, uids} =
        ProviderCalendarEventSchema
        |> where_sweepable(calendar_integration_id, provider_calendar_id, unwritten_since)
        |> where([e], e.id in ^chunk)
        |> select([e], e.uid)
        |> Repo.delete_all()

      uids
    end)
  end

  defp where_sweepable(query, calendar_integration_id, provider_calendar_id, unwritten_since) do
    where(
      query,
      [e],
      e.calendar_integration_id == ^calendar_integration_id and
        e.provider_calendar_id == ^provider_calendar_id and
        e.updated_at < ^unwritten_since and
        e.sync_state == ^@synced
    )
  end
end
