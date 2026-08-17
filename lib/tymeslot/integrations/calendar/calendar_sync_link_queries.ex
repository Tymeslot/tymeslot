defmodule Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries do
  @moduledoc """
  Data access for `calendar_sync_links`. All `Repo` calls for the sync-link
  configuration live here (RepoCallBoundary).

  Nothing in this module is user-scoped except `list_for_user/1`, and that one
  filters for the listing rather than for authorisation. A caller reaching
  `get/1`, `update/2` or `delete/1` directly from a LiveView therefore bypasses
  ownership entirely. The check belongs in the context, which — because a link
  names two integrations — has to verify the acting user owns *both* of them,
  not just the one it happens to be editing. `Appearance.with_owned_integration/3`
  is the pattern.

  Reads preload both integrations. The dashboard cannot render a link without
  naming its two ends, and leaving the preload to the caller is how a list view
  ends up issuing one query per row.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Repo

  @preloads [:source_integration, :target_integration]

  @doc """
  Every link the organiser has configured, oldest first, with both
  integrations preloaded.

  Ordered by id rather than by an edit timestamp so the list holds still: an
  organiser toggling one link's `enabled` should not watch the row jump to the
  top of the panel.
  """
  @spec list_for_user(integer()) :: [CalendarSyncLinkSchema.t()]
  def list_for_user(user_id) when is_integer(user_id) do
    CalendarSyncLinkSchema
    |> where([l], l.user_id == ^user_id)
    |> order_by([l], asc: l.id)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  Every enabled link that mirrors *out of* this integration.

  The inbound sync path's question, asked once per synced calendar rather than
  once per event. `enabled` is filtered in SQL rather than by the caller so a
  paused link costs nothing beyond the index scan that skipped it — and, more
  importantly, so that "paused means no writes" is enforced at the one place the
  sync path looks for work rather than at each of the places that act on it.

  The target integration is preloaded, and only that one. The enqueue itself
  needs nothing but `id`, but it is no longer the only consumer of this list:
  `SyncLink.MovedOccurrence` asks each link's target whether it can hold a
  series at all, and a link whose target is `NotLoaded` cannot be asked and is
  skipped — silently reporting nothing rather than reporting wrongly. One
  preload on a list already loaded once per sync is cheaper than the query per
  link the alternative costs. The source is deliberately left off: it is the
  integration the caller already holds.
  """
  @spec list_enabled_for_source(integer()) :: [CalendarSyncLinkSchema.t()]
  def list_enabled_for_source(source_integration_id) when is_integer(source_integration_id) do
    CalendarSyncLinkSchema
    |> where([l], l.source_integration_id == ^source_integration_id and l.enabled == true)
    |> order_by([l], asc: l.id)
    |> preload(:target_integration)
    |> Repo.all()
  end

  def list_enabled_for_source(_source_integration_id), do: []

  @doc """
  Every link naming this integration at either end, enabled or not.

  The teardown question, and deliberately not `list_enabled_for_source/1`'s.
  Disconnecting a calendar has to withdraw the placeholders on it *and* the
  placeholders it caused on other calendars, and a paused link's mirrors are
  still sitting on a provider — pausing leaves them in place by design. So this
  filters on neither direction nor `enabled`: a filter here would be a
  placeholder nobody ever removes.

  No preloads. The caller withdraws mirrors keyed on `target_integration_id`,
  which the mirror row carries itself.
  """
  @spec list_for_integration(integer()) :: [CalendarSyncLinkSchema.t()]
  def list_for_integration(integration_id) when is_integer(integration_id) do
    CalendarSyncLinkSchema
    |> where(
      [l],
      l.source_integration_id == ^integration_id or l.target_integration_id == ^integration_id
    )
    |> order_by([l], asc: l.id)
    |> Repo.all()
  end

  def list_for_integration(_integration_id), do: []

  @doc """
  Every enabled link whose last reconciliation is older than `max_age_seconds`,
  or which has never been reconciled.

  The reconcile sweep's selection, and deliberately not the same question as
  "every enabled link". A sweep that re-enqueued every link on every run would
  make the cadence of the cron entry the cadence of the work, so a link already
  reconciled a minute ago by a manual trigger or by a previous run that
  overlapped would be re-diffed anyway. Filtering on `last_reconciled_at` makes
  the interval a property of the link rather than of the schedule.

  `nil` sorts as due. A link created between two sweeps has never been
  reconciled and is exactly the one whose mirrors are most likely to be
  missing.

  A **disabled** link is included when it still holds mappings in
  `pending_delete`, and that exception is load-bearing rather than tidy.
  Teardown disables the link before withdrawing its placeholders, so a provider
  that refuses the delete leaves exactly that combination: a disabled link whose
  busy blocks are still on someone's calendar. Filtering on `enabled` alone
  removed those links from the retry mechanism their own teardown depends on —
  the orphan the teardown exists to prevent, reached through its recovery path,
  and reachable from link removal, calendar disconnect and account deletion
  alike. An ordinarily paused link has no `pending_delete` rows and is still
  skipped, which is what pausing means.

  No preloads: the sweep enqueues jobs keyed on `id` and never looks at either
  integration, so loading two per link would fetch rows nothing reads.
  """
  @spec list_due_for_reconcile(non_neg_integer()) :: [CalendarSyncLinkSchema.t()]
  def list_due_for_reconcile(max_age_seconds) when is_integer(max_age_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)

    pending_delete =
      from(m in CalendarSyncMirrorSchema,
        where:
          m.sync_link_id == parent_as(:link).id and
            m.state == ^CalendarSyncMirrorSchema.state_pending_delete()
      )

    from(l in CalendarSyncLinkSchema, as: :link)
    |> where([l], l.enabled == true or exists(subquery(pending_delete)))
    |> where([l], is_nil(l.last_reconciled_at) or l.last_reconciled_at < ^cutoff)
    |> order_by([l], asc: l.id)
    |> Repo.all()
  end

  @doc """
  Every user id that has at least one link configured, ascending.

  The orphan scan's selection. It asks its question per organiser — a
  placeholder is unclaimed relative to everything that organiser owns, not
  relative to one link — so the sweep needs the set of organisers rather than
  the set of links.

  Links are counted whether enabled or not. A disabled link's placeholders are
  still on the target, and a link disabled by a teardown that could not finish
  is the case most likely to have left one behind; filtering on `enabled` would
  hide exactly the organiser worth scanning.
  """
  @spec list_user_ids_with_links() :: [integer()]
  def list_user_ids_with_links do
    CalendarSyncLinkSchema
    |> select([l], l.user_id)
    |> distinct(true)
    |> order_by([l], asc: l.user_id)
    |> Repo.all()
  end

  @doc """
  One link by id, with both integrations preloaded.

  Answers `{:error, :not_found}` for a missing row and for an id that is not an
  integer, so a value straight off a form parameter cannot raise here.
  """
  @spec get(integer() | any()) :: {:ok, CalendarSyncLinkSchema.t()} | {:error, :not_found}
  def get(id) when is_integer(id) do
    case Repo.get(CalendarSyncLinkSchema, id) do
      nil -> {:error, :not_found}
      link -> {:ok, Repo.preload(link, @preloads)}
    end
  end

  def get(_id), do: {:error, :not_found}

  @doc """
  Creates a link.

  `attrs` must carry `:target_provider` for the read-only-target and
  CalDAV-calendar rules to apply — see `CalendarSyncLinkSchema`'s moduledoc for
  why the provider arrives as a virtual field rather than being looked up here.
  """
  @spec create(map()) :: {:ok, CalendarSyncLinkSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %CalendarSyncLinkSchema{}
    |> CalendarSyncLinkSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Persists a changeset the caller has already built.

  The context builds a focused changeset for a write that must not re-validate
  the whole row — pausing a link, in particular. Keeping the `Repo` call here
  means that path still goes through the query module rather than reaching for
  `Repo` itself.
  """
  @spec update_changeset(Ecto.Changeset.t()) ::
          {:ok, CalendarSyncLinkSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_changeset(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)

  @spec update(CalendarSyncLinkSchema.t(), map()) ::
          {:ok, CalendarSyncLinkSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%CalendarSyncLinkSchema{} = link, attrs) do
    link
    |> CalendarSyncLinkSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a link, and with it every mirror mapping and conflict record the
  database cascades away.

  The placeholders already written onto the target are *not* removed by this:
  the rows recording where they are go first, so tearing them down is the
  caller's job before deleting. Pausing through `enabled` is the operation that
  leaves mirrors intact.
  """
  @spec delete(CalendarSyncLinkSchema.t()) ::
          {:ok, CalendarSyncLinkSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%CalendarSyncLinkSchema{} = link), do: Repo.delete(link)

  @doc "A changeset for the dashboard form to render and re-render on change."
  @spec change(CalendarSyncLinkSchema.t(), map()) :: Ecto.Changeset.t()
  def change(%CalendarSyncLinkSchema{} = link, attrs \\ %{}) do
    CalendarSyncLinkSchema.changeset(link, attrs)
  end
end
