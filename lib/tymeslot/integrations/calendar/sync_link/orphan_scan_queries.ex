defmodule Tymeslot.Integrations.Calendar.SyncLink.OrphanScanQueries do
  @moduledoc """
  The cache reads `SyncLink.OrphanScan` needs, kept apart from
  `ProviderCalendarEventQueries`.

  They exist for one caller and answer one question — which cached events could
  be placeholders — where that module answers the general cache. Splitting them
  keeps the general one from growing a section that only the orphan scan reads.

  All three are shaped for a scan that runs unattended on a schedule rather
  than for one an operator invokes and waits on: each answers about a whole
  integration in a bounded number of round trips, so the sweep's cost tracks the
  number of links rather than the number of events on anyone's calendar.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  # Well under Postgres' 65,535 bound on bind parameters, leaving room for the
  # integration id and for the driver's own overhead. The scan derives three
  # identities per cached source event, so this is roughly a 1,600-event
  # calendar per round trip.
  @uid_batch_size 5_000

  @doc """
  Cached events on the given integrations whose UID carries `prefix`.

  `SyncLink.OrphanScan` asks this rather than reading `created_by_tymeslot`,
  which is true of every event Tymeslot writes, bookings included. The prefix is
  escaped before `like/2` sees it, so a caller cannot widen the match.
  """
  @spec list_by_uid_prefix([integer()], String.t()) :: [ProviderCalendarEventSchema.t()]
  def list_by_uid_prefix([], _prefix), do: []

  def list_by_uid_prefix(integration_ids, prefix)
      when is_list(integration_ids) and is_binary(prefix) do
    pattern = escape_like(prefix) <> "%"

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], like(e.uid, ^pattern))
    |> Repo.all()
  end

  @doc """
  Every cached event UID for one integration.

  `SyncLink.OrphanScan` derives placeholder identities from these — the only
  direction that works for Google, whose id is a hash of ours.
  """
  @spec list_uids_for_integration(integer()) :: [String.t()]
  def list_uids_for_integration(calendar_integration_id)
      when is_integer(calendar_integration_id) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> select([e], e.uid)
    |> Repo.all()
  end

  @doc """
  The cached events on one integration matching any of the given UIDs.

  `SyncLink.OrphanScan` derives three candidate identities per source event —
  the UID a write would be addressed to, the id Google would hash it to, and
  that id suffixed with Google's domain — and needs the rows that exist under
  any of them. Asking one UID at a time is the shape this replaces: a link over
  a 2,000-event calendar derives 6,000 identities and issued 6,000 sequential
  single-row queries to check them, a cost never observed only because nothing
  outside the tests ever ran the scan.

  The set is chunked because the derived list grows with the source calendar
  rather than with anything bounded, and Postgres' parameter limit is 65,535 —
  a 25,000-event calendar would otherwise build a query the server refuses.
  Rows are returned in no particular order; the caller deduplicates by
  `{integration, uid}` regardless, since the same row can answer more than one
  candidate.
  """
  @spec list_by_uids(integer(), [String.t()]) :: [ProviderCalendarEventSchema.t()]
  def list_by_uids(_calendar_integration_id, []), do: []

  def list_by_uids(calendar_integration_id, uids)
      when is_integer(calendar_integration_id) and is_list(uids) do
    uids
    |> Enum.uniq()
    |> Enum.chunk_every(@uid_batch_size)
    |> Enum.flat_map(fn batch ->
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where([e], e.uid in ^batch)
      |> Repo.all()
    end)
  end

  # Escapes LIKE metacharacters so a prefix is matched literally rather than as
  # a pattern — a caller cannot widen the match to every cached row.
  defp escape_like(term) do
    String.replace(term, ~r/[\\%_]/, "\\\\\\0")
  end
end
