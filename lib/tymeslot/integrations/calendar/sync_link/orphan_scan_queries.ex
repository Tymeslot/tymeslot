defmodule Tymeslot.Integrations.Calendar.SyncLink.OrphanScanQueries do
  @moduledoc """
  The two cache reads `SyncLink.OrphanScan` needs, kept apart from
  `ProviderCalendarEventQueries`.

  They exist for one caller and answer one question — which cached events could
  be placeholders — where that module answers the general cache. Splitting them
  keeps the general one from growing a section that only the orphan scan reads.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

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

  # Escapes LIKE metacharacters so a prefix is matched literally rather than as
  # a pattern — a caller cannot widen the match to every cached row.
  defp escape_like(term) do
    String.replace(term, ~r/[\\%_]/, "\\\\\\0")
  end
end
