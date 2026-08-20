defmodule Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries do
  @moduledoc """
  Data access for `calendar_sync_mirrors`. All `Repo` calls for the mirror
  mappings live here (RepoCallBoundary).

  Two readers, pulling in opposite directions:

  `get_by_link_and_source_uid/2` is the engine's forward lookup — from a link
  and the source event it is processing to the placeholder already written, or
  nothing. It rides the unique index on `[sync_link_id, source_uid]`.

  `mirror_uids_for_integrations/1` is the calendar grid's backward lookup —
  from the integrations whose events it is about to draw to the UIDs among them
  that are mirrors and must be hidden. It rides
  `calendar_sync_mirrors_target_uid_index` on
  `[target_integration_id, target_uid]`, which exists solely for this question:
  without it the grid falls to a sequential scan of every mirror row in the
  installation, on every render, and the grid re-renders on navigation, on live
  cache updates, and on every appearance change.

  The backward lookup returns a `MapSet` rather than a list because its caller
  is a per-event membership test inside a render loop. Handing back a list
  would turn one filter pass into a scan per event.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId
  alias Tymeslot.Repo

  @type write_result ::
          {:ok, CalendarSyncMirrorSchema.t()} | {:error, Ecto.Changeset.t()}

  @doc """
  The mapping this link holds for one source event, if it has mirrored it.
  """
  @spec get_by_link_and_source_uid(integer(), String.t()) ::
          {:ok, CalendarSyncMirrorSchema.t()} | {:error, :not_found}
  def get_by_link_and_source_uid(sync_link_id, source_uid)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    case Repo.get_by(CalendarSyncMirrorSchema,
           sync_link_id: sync_link_id,
           source_uid: source_uid
         ) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_by_link_and_source_uid(_sync_link_id, _source_uid), do: {:error, :not_found}

  @doc """
  Every mirror living on the given target integrations, as a set of
  `{integration_id, target_uid}` pairs.

  Measured at 100,000 mirror rows across 20 target integrations, selecting
  five of them: a Bitmap Index Scan on
  `[target_integration_id, target_uid]` feeding a Bitmap Heap Scan, ~4.9 ms.
  Not an index-only scan — the visibility map on a table this write-heavy is
  rarely all-visible, so the heap is still read — but the index is what keeps
  the row count proportional to the integrations asked for rather than to
  every mirror in the installation.

  `pending_delete` mirrors are included deliberately. Their placeholder is
  still on the provider until it confirms the delete, so it is still in the
  event cache and still needs hiding; dropping it from this set would make the
  mirror flash into the organiser's grid for exactly as long as the teardown
  takes.
  """
  @spec mirror_uids_for_integrations([integer()]) :: MapSet.t({integer(), String.t()})
  def mirror_uids_for_integrations([]), do: MapSet.new()

  def mirror_uids_for_integrations(integration_ids) when is_list(integration_ids) do
    CalendarSyncMirrorSchema
    |> where([m], m.target_integration_id in ^integration_ids)
    |> select([m], {m.target_integration_id, m.target_uid, m.target_provider_event_id})
    |> Repo.all()
    |> Enum.flat_map(&identifiers_for/1)
    |> MapSet.new()
  end

  @doc """
  The loop-prevention set for one calendar's inbound sync.

  Unlike `mirror_uids_for_integrations/1`, which answers "which cached rows on
  *these* calendars are placeholders" and is keyed on `target_integration_id`,
  this answers the question the sync actually has: "is the event I just fetched
  from this calendar one of ours?" Those differ whenever a placeholder is not on
  the calendar it was written for.

  That is not hypothetical. A mirror whose target had been deauthorised was
  redirected by `BookingIntegrationResolver` onto the organiser's primary
  calendar — the link's *source*. Keyed on the target, the source's own sync
  found no match, read each placeholder as an ordinary event and mirrored it
  again; one real event grew copies three generations deep inside two minutes.

  So the rows are selected by the *link*, not by the mirror's target: every
  placeholder belonging to a link that names this calendar at either end is
  recognised, whichever end it ended up on. The set stays scoped to links this
  calendar participates in, so one organiser's placeholders can never mask
  another organiser's real events.

  Keys are `{integration_id, identifier}` with `integration_id` fixed to the
  calendar being synced, because that is the key
  `Eligibility.already_a_mirror?/2` tests and the two must not drift.
  """
  @spec mirror_uids_for_sync(integer()) :: MapSet.t({integer(), String.t()})
  def mirror_uids_for_sync(integration_id) when is_integer(integration_id) do
    CalendarSyncMirrorSchema
    |> join(:inner, [m], l in CalendarSyncLinkSchema, on: l.id == m.sync_link_id)
    |> where(
      [_m, l],
      l.source_integration_id == ^integration_id or l.target_integration_id == ^integration_id
    )
    |> select([m], {m.target_uid, m.target_provider_event_id})
    |> Repo.all()
    |> Enum.flat_map(fn {target_uid, provider_event_id} ->
      target_uid
      |> ProviderEventId.cache_identities(provider_event_id)
      |> Enum.map(&{integration_id, &1})
    end)
    |> MapSet.new()
  end

  # Every identity a placeholder can be cached under, because the two provider
  # families disagree about whose UID survives a write.
  #
  # The CalDAV family stores the UID it is handed, so `target_uid` comes back
  # unchanged. Google does not: a create sends `id`, and Google answers with an
  # iCalUID of its own making — `{id}@google.com` — which is what the next
  # inbound sync caches. The UID we asked for is then nowhere in the cache, and
  # a set built only from `target_uid` recognises none of our own placeholders.
  #
  # That is not a theoretical gap. Every one of 317 cached placeholders on a
  # live installation was unrecognisable this way, which disabled loop
  # prevention completely: each placeholder read as an ordinary event, was
  # mirrored back across the link, and one real event accumulated a second and
  # third "Busy" on the calendar it started on.
  #
  # A mirror whose write never landed has no provider id, and `nil` is dropped
  # rather than added — a set containing it would match every cached event
  # whose uid is also absent.
  #
  # The stored provider id is Google's bare event id, because that is what the
  # write answered with: `convert_event/1` reads the response's `"id"`. The
  # *cache* is filled by the normaliser, which prefers `"iCalUID"` — the same
  # id with `@google.com` appended. So the id as recorded never equals the uid
  # as cached, and the suffixed form has to be in the set too or the row still
  # recognises nothing. Expanding here rather than at the write keeps every
  # mapping already in the database working, including the ones written before
  # the id was recorded correctly.
  #
  # `ProviderEventId.cache_identities/2` is where that expansion is stated, and
  # it is stated once: `SyncLink.ConflictLog` asks the same question of the same
  # two columns, and the version of it that was written out separately looked up
  # `target_uid` alone and resolved none of 105 live mirrors.
  defp identifiers_for({integration_id, target_uid, provider_event_id}) do
    target_uid
    |> ProviderEventId.cache_identities(provider_event_id)
    |> Enum.map(&{integration_id, &1})
  end

  @doc """
  Every mapping this link holds, in whatever state.

  The reconcile sweep's half of the diff. `pending_delete` and `failed` rows are
  returned alongside `active` ones on purpose: those are precisely the mappings
  whose last write did not land, and a sweep that could not see them would leave
  a half-torn-down placeholder on the target forever.
  """
  @spec list_for_link(integer()) :: [CalendarSyncMirrorSchema.t()]
  def list_for_link(sync_link_id) when is_integer(sync_link_id) do
    CalendarSyncMirrorSchema
    |> where([m], m.sync_link_id == ^sync_link_id)
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  @doc """
  Moves every mapping this link holds into `pending_delete`, in one statement.

  The first step of tearing a link down, and it runs *before* the provider is
  asked to remove anything. If the process dies between the transition and the
  last provider delete, the rows left behind are already in the state the
  reconcile sweep looks for, so the teardown resumes rather than stalling with
  rows that still claim to be `active`.

  One `UPDATE` rather than a row at a time: a link with a year of history can
  hold thousands of mappings, and the transition carries no per-row decision.

  Returns the number of rows moved.
  """
  @spec mark_pending_delete_for_link(integer()) :: non_neg_integer()
  def mark_pending_delete_for_link(sync_link_id) when is_integer(sync_link_id) do
    {count, _returned} =
      CalendarSyncMirrorSchema
      |> where([m], m.sync_link_id == ^sync_link_id)
      |> Repo.update_all(
        set: [
          state: CalendarSyncMirrorSchema.state_pending_delete(),
          updated_at: DateTime.utc_now()
        ]
      )

    count
  end

  @doc """
  The mappings a teardown left behind on this link.

  A `pending_delete` row is a placeholder the organiser has asked to be rid of
  and the provider would not remove. It is the one thing still worth doing for a
  link that is otherwise disabled, so the reconcile worker asks for exactly
  these rather than diffing a link nobody wants written to.
  """
  @spec list_pending_delete_for_link(integer()) :: [CalendarSyncMirrorSchema.t()]
  def list_pending_delete_for_link(sync_link_id) when is_integer(sync_link_id) do
    CalendarSyncMirrorSchema
    |> where(
      [m],
      m.sync_link_id == ^sync_link_id and
        m.state == ^CalendarSyncMirrorSchema.state_pending_delete()
    )
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  @doc """
  Records a placeholder the engine has just written onto a target.

  Returning the changeset error rather than raising is what makes orphan
  compensation possible: the engine sees the failure, deletes the provider event
  it created a moment ago, and lets the retry start from nothing.
  """
  @spec create(map()) :: write_result()
  def create(attrs) do
    %CalendarSyncMirrorSchema{}
    |> CalendarSyncMirrorSchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(CalendarSyncMirrorSchema.t(), map()) :: write_result()
  def update(%CalendarSyncMirrorSchema{} = mirror, attrs) do
    mirror
    |> CalendarSyncMirrorSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Drops the mapping once the provider has confirmed the placeholder is gone.

  Deleting the row is what ends the mirror's life, so it must not happen before
  the provider delete succeeds: the row holds the only record of which provider
  event to remove, and losing it strands the placeholder on the target with
  nothing owning it. `pending_delete` is the state for the interval between the
  source disappearing and the provider confirming.
  """
  @spec delete(CalendarSyncMirrorSchema.t()) :: write_result()
  def delete(%CalendarSyncMirrorSchema{} = mirror), do: Repo.delete(mirror)
end
