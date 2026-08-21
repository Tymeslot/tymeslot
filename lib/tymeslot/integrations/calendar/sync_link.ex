defmodule Tymeslot.Integrations.Calendar.SyncLink do
  @moduledoc """
  The organiser's cross-calendar mirroring configuration: which calendar's
  events get a placeholder written onto which other calendar, and under what
  privacy tier.

  A focused sibling of `Tymeslot.Integrations.Calendar` in the shape
  `Tymeslot.Integrations.Calendar.Appearance` established: the context owns
  connecting and syncing calendars, and this owns the relationships configured
  between the ones already connected.

  ## Why authorisation lives here and nowhere else

  `CalendarSyncLinkQueries` is not user-scoped. `get/1`, `update/2` and
  `delete/1` take an id and act on whatever row carries it, so a LiveView
  reaching for a query module directly hands the browser a way to edit another
  organiser's links by guessing an integer. Every write on this module
  therefore takes the acting user's id and verifies ownership before touching a
  row, answering `{:error, :not_found}` — not `:forbidden` — so a forged id
  cannot be used to probe which ids exist.

  A sync link is harder to guard than an appearance row, because it names
  *two* integrations. Both are forgeable and both are checked: naming a
  stranger's calendar as either end fails, and the check runs before the
  changeset so no row is written and no error message reveals anything about
  the calendar named. `owned_by?/2` rather than `get_for_user/2`, following
  `Appearance.with_owned_integration/3`: the latter decrypts credentials and
  can answer `:requires_reencryption`, neither of which has any bearing on
  whether a link may be configured.

  ## Why the context loads the target integration

  Two changeset rules — a read-only subscription can never be a mirror target,
  and the CalDAV family ignores a calendar id on write — depend on the target's
  provider, which a changeset cannot look up. `CalendarSyncLinkSchema` takes it
  as the virtual `:target_provider` field and, crucially, *skips both rules*
  when it is absent rather than failing. A caller that forgets it gets a link
  pointing at an ICS feed that will fail on every mirror write forever. This
  module is the one place that guarantees it is supplied: the ownership check
  already loads the target integration, so the provider is in hand and there is
  no second query to pay for.
  """

  import Ecto.Changeset, only: [force_change: 3]

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Remirror
  alias Tymeslot.Integrations.Calendar.SyncLink.TargetMove
  alias Tymeslot.Integrations.Calendar.SyncLink.Teardown

  @type result ::
          {:ok, CalendarSyncLinkSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
  Every link the organiser has configured, with both ends preloaded for the
  dashboard to name them.
  """
  @spec list_links(integer()) :: [CalendarSyncLinkSchema.t()]
  def list_links(user_id) when is_integer(user_id),
    do: CalendarSyncLinkQueries.list_for_user(user_id)

  @doc """
  Configures a new mirroring relationship.

  `attrs` carries the two integration ids and the optional presentation
  choices; `user_id` and `target_provider` are supplied here and any value the
  caller passed for them is overwritten, so a form parameter cannot claim
  another organiser's id or a provider its target does not have.
  """
  @spec create_link(integer(), map()) :: result()
  def create_link(user_id, attrs) when is_integer(user_id) do
    source_id = fetch_id(attrs, :source_integration_id)
    target_id = fetch_id(attrs, :target_integration_id)

    with_owned_pair(user_id, source_id, target_id, fn target_provider ->
      attrs
      |> normalise(user_id, source_id, target_id, target_provider)
      |> CalendarSyncLinkQueries.create()
    end)
  end

  @doc """
  Saves a whole grid of source→target cells at once.

  The link matrix presents every ordered pair of the organiser's calendars
  together, so a save is a diff against what is already configured rather than
  a series of creates: cells newly filled become links, cells emptied become
  deletions, and — the rule the rest of this function exists to protect — cells
  that did not move are not touched at all.

  ## The three states a cell carries

  `cells` maps `{source_integration_id, target_integration_id}` to `:active` or
  `:paused`; a pair absent from the map is deleted. The middle state is what
  lets the grid stop being a delete button.

  A cell used to mean "this link exists", so clearing one ran `delete_link/2`
  and withdrew every placeholder the link had written — permanently, from a
  single misclick, and the busy blocks it removed are deliberately
  indistinguishable from ordinary events, so the organiser could not tell what
  had gone. `:paused` is the reversible answer to "stop mirroring this": the
  row keeps its privacy tier, its label and its target calendar, and writes
  nothing until it is resumed. Deletion is still reachable, but only as a
  deliberate action on the link itself.

  A pair that is present in both the map and the database, differing only in
  `enabled`, therefore moves through `toggle_enabled/3`. It must not be
  recreated: the settings live on the row, and a delete-then-create would reset
  every one of them to its default while tearing the placeholders down on the
  way past.

  ## Why an unmoved cell is not rewritten

  Recreating an unchanged link means deleting it first, and `delete_link/2`
  withdraws every placeholder it has written from the provider on its way out.
  A save that rebuilt the whole grid would therefore tear down and rewrite
  every mirror in the set, turning a no-op into a burst of provider writes and
  leaving the organiser's other calendars briefly empty of the busy blocks that
  are the entire point.

  ## Why this is not a transaction

  Every cell is validated before any cell is written, so an invalid pair
  rejects the save whole rather than applying half of it. That check could not
  be a `Repo.transaction` even if it were convenient: deletion runs
  `Teardown.tear_down_link/2`, which deletes placeholders from Google, Outlook
  or a CalDAV server, and holding a database transaction open across those
  calls would tie up a pool connection for the length of a provider's
  latency — the failure the sync path is carefully built to avoid.

  Validation covers what the caller can forge: both ends of every pair must
  belong to the acting user, and no cell may name one calendar twice. What it
  cannot pre-empt is a provider refusing a withdrawal mid-save; a partial
  result is reported honestly rather than rolled back, because the placeholders
  already removed cannot be restored by a database rollback.

  Anything already linked but absent from the map is deleted, which is what
  makes clearing a row of the grid work.
  """
  @spec apply_matrix(integer(), %{{integer(), integer()} => :active | :paused}) ::
          {:ok, %{created: non_neg_integer(), deleted: non_neg_integer()}}
          | {:error, :not_found | :self_link | term()}
  def apply_matrix(user_id, cells) when is_integer(user_id) and is_map(cells) do
    desired = MapSet.new(Map.keys(cells))

    with :ok <- validate_cells(user_id, desired) do
      existing = existing_cells(user_id)

      to_create = for {pair, state} <- cells, not is_map_key(existing, pair), do: {pair, state}
      to_delete = for {pair, link} <- existing, not MapSet.member?(desired, pair), do: link

      to_toggle =
        for {pair, link} <- existing,
            state = Map.get(cells, pair),
            not is_nil(state),
            link.enabled != (state == :active),
            do: {link, state == :active}

      with {:ok, created} <- create_cells(user_id, to_create),
           :ok <- toggle_cells(user_id, to_toggle) do
        delete_cells(user_id, to_delete, created)
      end
    end
  end

  @doc """
  Edits an existing link.

  The target may move, so ownership is re-verified against the target the
  attributes ask for rather than the one already stored, and the provider
  handed to the changeset is that new target's.

  ## Why an edit can withdraw placeholders

  Re-pointing a link is `delete_link/2`'s hazard reached by another route. The
  placeholders are on the calendar the link *used to* name, and the mapping
  rows go on pointing at them while the link points somewhere else — so nothing
  will ever remove them, and a busy block is deliberately indistinguishable
  from an ordinary one, so the organiser will not know what it is. An edit that
  invalidates the mappings therefore withdraws them first, through the same
  `SyncLink.Teardown` that link removal uses. `SyncLink.TargetMove` decides
  which edits those are.

  ## The order, and what a failure leaves behind

  Teardown reads the link *as it stands*, so it must run before the row is
  written — a withdrawal aimed at the new target would ask a calendar that
  never held the placeholders, draw a 404 that reads as "already gone", and
  drop the only rows naming them. And it must succeed before the row is
  written: a failed withdrawal followed by a successful re-point is exactly the
  orphan this exists to prevent, arrived at with the evidence destroyed.

  So a provider that refuses the delete surfaces its own reason — the same
  `{:error, term()}` `delete_link/2` answers with — and the link keeps its old
  target untouched. The organiser's edit did not happen and they are told so;
  the mappings are left in `pending_delete`, which is the state the reconcile
  sweep retries, so the withdrawal finishes on its own and the edit can be
  saved again.

  Validation comes before all of it. An invalid changeset — a target that is a
  read-only subscription, say — returns the changeset and withdraws nothing:
  the link is not moving, so its placeholders are still exactly where the
  mappings say they are, and emptying the target for a save that was refused
  would be destruction in exchange for nothing.

  ## What refills the new target

  Nothing here. A successful teardown drops the mapping rows, so the link
  starts empty, and `Workers.SyncLinkReconcileWorker` enqueues an `:upsert` for
  every eligible source event it finds without one — which, with no mappings
  left, is all of them. That is why `enabled` is restored below: teardown
  pauses the link on its way through, and
  `CalendarSyncLinkQueries.list_due_for_reconcile/1` skips a disabled link
  holding no `pending_delete` rows, so a move that left it paused would leave
  the new target permanently empty. Restoring the *stored* value rather than
  forcing `true` keeps a deliberately paused link paused.

  The refill therefore arrives on the next sweep rather than immediately. No
  job is enqueued for a move.

  ## Why an edit can rewrite placeholders instead

  The edits that are not moves divide again. A tier, a label or a colour leaves
  every placeholder where it is and changes what it *says*, and nothing else in
  the system notices: the push path fires on a source event changing, and the
  reconcile sweep compares the source's timestamp against the mapping's, so a
  link switched to `generic_label` kept saying "Busy" until somebody happened
  to edit the source. `SyncLink.Remirror` decides which edits those are and
  enqueues an `:upsert` per mapping, each rebuilding its payload from the link
  as saved.

  Only one of the two ever runs. A save that both re-points and re-labels tears
  the mappings down, which leaves nothing to rewrite — see `apply_edit/3`.
  """
  @spec update_link(integer(), integer() | any(), map()) :: result() | {:error, term()}
  def update_link(user_id, link_id, attrs) when is_integer(user_id) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      source_id = fetch_id(attrs, :source_integration_id) || link.source_integration_id
      target_id = fetch_id(attrs, :target_integration_id) || link.target_integration_id

      with_owned_pair(user_id, source_id, target_id, fn target_provider ->
        link
        |> CalendarSyncLinkQueries.change(
          normalise(attrs, user_id, source_id, target_id, target_provider)
        )
        |> apply_edit(link, user_id)
      end)
    end
  end

  @doc """
  Pauses or resumes one link.

  Pausing leaves the placeholders already written on the target in place; only
  deleting the link tears the mapping rows down.

  ## Why the two directions do not share a changeset

  Not routed through `update_link/3`, and deliberately so. Pausing is the
  control an organiser reaches for when a link is misbehaving, so it has to
  work on a link that is misbehaving — including a row whose stored attributes
  no longer satisfy a validation added after it was written.
  `CalendarSyncLinkSchema.enabled_changeset/2` records what that cost: routing
  the pause through the full changeset turned "pause this" into an error about
  a label the write never touches, and the one thing an organiser could do
  about a bad link was the thing that failed.

  Resuming is the other operation. It starts writes rather than stopping them,
  and one property of the target decides whether they can land at all: an
  integration reconnected as a subscription while a link pointed at it answers
  `{:error, :read_only}` to every create, so a resume would schedule a write
  that fails forever. `CalendarSyncLinkSchema.resume_changeset/2` therefore
  applies that single rule and no other — the target's provider is loaded here
  for it, the way `create_link/2` and `update_link/3` load it, since a
  changeset cannot read the integration row itself.

  So a read-only target refuses the resume and still permits the pause. The
  asymmetry is the point: a link whose target went read-only is exactly a
  misbehaving link, and refusing to pause it would leave the organiser holding
  one they can neither fix nor stop.
  """
  @spec toggle_enabled(integer(), integer() | any(), boolean()) :: result()
  def toggle_enabled(user_id, link_id, enabled) when is_boolean(enabled) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      link
      |> toggle_changeset(user_id, enabled)
      |> CalendarSyncLinkQueries.update_changeset()
    end
  end

  @doc """
  Removes a link, withdrawing every placeholder it wrote before the row that
  names them goes.

  The order is not an optimisation, it is the whole operation.
  `on_delete: :delete_all` takes the mapping rows with the link, and those rows
  hold the only record of which event on the target calendar is a mirror — so
  deleting the link first leaves busy blocks on the organiser's other calendar
  that nothing owns and nothing will ever remove. `SyncLink.Teardown` documents
  the sequence.

  A placeholder that cannot be withdrawn therefore *keeps the link*. The link
  is left disabled with its mapping in `pending_delete`, which is the state the
  reconcile sweep retries, and the error surfaces so the dashboard can say the
  removal did not complete. The alternative — deleting anyway — is precisely
  the orphan this refuses to create.
  """
  @spec delete_link(integer(), integer() | any()) :: result() | {:error, term()}
  def delete_link(user_id, link_id) when is_integer(user_id) do
    with {:ok, link} <- owned_link(user_id, link_id),
         :ok <- Teardown.tear_down_link(link, user_id) do
      CalendarSyncLinkQueries.delete(link)
    end
  end

  @doc """
  A changeset for rendering a link's fields, validated without a target
  provider.

  It carries no `:target_provider` and does not load one. The two rules that
  depend on it — a read-only subscription cannot be a mirror target, and the
  CalDAV family ignores a chosen calendar id — are the ones
  `CalendarSyncLinkSchema` skips when the field is absent, so this changeset
  answers under *fewer* rules than the write that follows it will apply. A
  caller using it to decide whether a save will be accepted will be told yes on
  configurations `create_link/2` and `update_link/3` refuse.

  That is survivable only because nothing renders a form from it: the dashboard
  panel builds its fields from the submitted params and reports errors from the
  changeset the *write* returned, which is the one carrying the provider. A
  caller that does need the write's verdict should ask for it through
  `update_link/3` rather than pre-flighting it here.
  """
  @spec change_link(CalendarSyncLinkSchema.t(), map()) :: Ecto.Changeset.t()
  def change_link(%CalendarSyncLinkSchema{} = link, attrs \\ %{}),
    do: CalendarSyncLinkQueries.change(link, attrs)

  # A pause asks nothing of the target, so it loads nothing: the extra query
  # would buy a fact no rule reads, on the one operation that has to work when
  # everything else about the link is wrong.
  defp toggle_changeset(link, _user_id, false),
    do: CalendarSyncLinkSchema.enabled_changeset(link, false)

  # A resume needs the provider the target has *now*, not the one it had when
  # the link was configured, which is the entire scenario the rule exists for.
  # `provider_for_owner/2` rather than a bare lookup, for the reason the
  # moduledoc gives: nothing in this module reads an integration row without
  # first proving the acting organiser owns it.
  #
  # A target that answers nothing — deleted, or moved to another owner — hands
  # `nil` to a changeset that skips the rule for a missing provider, so the
  # resume proceeds. That is the same position `enabled_changeset/2` takes: the
  # write is refused by the engine's own provider guard and the foreign key, and
  # neither is worth pre-empting at the cost of a toggle that cannot run.
  defp toggle_changeset(link, user_id, true) do
    target_provider =
      case CalendarIntegrationQueries.provider_for_owner(link.target_integration_id, user_id) do
        {:ok, provider} -> provider
        {:error, :not_found} -> nil
      end

    CalendarSyncLinkSchema.resume_changeset(link, target_provider)
  end

  # An invalid changeset is returned before anything is withdrawn — see the
  # docstring. `Repo.update/1` would answer the same error, but only after the
  # teardown had already emptied the target for a save that never landed.
  defp apply_edit(%Ecto.Changeset{valid?: false} = changeset, _link, _user_id),
    do: {:error, changeset}

  # The two classes of edit are exclusive, and the re-point wins when one save
  # is both. Teardown drops every mapping row, so a re-mirror afterwards would
  # have nothing to iterate — and if it did, each job would name a mapping that
  # no longer exists. The sweep refills the new target from scratch, under the
  # presentation this same save stored, so the placeholders arrive saying the
  # new thing without a second mechanism aiming at rows that are gone.
  defp apply_edit(changeset, link, user_id) do
    if TargetMove.repoint?(link, changeset) do
      with :ok <- Teardown.tear_down_link(link, user_id) do
        changeset
        |> restore_enabled(link)
        |> CalendarSyncLinkQueries.update_changeset()
      end
    else
      changeset
      |> CalendarSyncLinkQueries.update_changeset()
      |> remirror_when_presentation_changed(link, changeset)
    end
  end

  # After the write, never before. The rewrite is for placeholders that
  # disagree with a link as *stored*, so an edit the database refused has
  # nothing to answer for, and the saved struct is what decides whether a
  # paused link is asked to write.
  defp remirror_when_presentation_changed({:ok, saved}, link, changeset) do
    if Remirror.presentation_change?(link, changeset), do: Remirror.enqueue_remirror(saved)

    {:ok, saved}
  end

  defp remirror_when_presentation_changed(outcome, _link, _changeset), do: outcome

  # Teardown paused the link in the database; the changeset was built from the
  # struct as it was before that and so carries no `enabled` change at all,
  # which means `Repo.update/1` would write every other field and leave the row
  # disabled. Putting the pre-teardown value back makes the pause last exactly
  # as long as the withdrawal it was there to protect.
  #
  # `force_change/3` rather than `put_change/3`, and that is the whole point of
  # the line: the changeset's data still holds the value the row carried before
  # teardown, so `put_change/3` sees "same as data", records no change, and
  # writes nothing — leaving the link disabled by exactly the route this is
  # here to close.
  defp restore_enabled(changeset, %CalendarSyncLinkSchema{enabled: enabled}),
    do: force_change(changeset, :enabled, enabled)

  # Both ends must belong to the acting user. The target's check is
  # `provider_for_owner/2` rather than `owned_by?/2` because the same query
  # answers ownership and yields the provider the changeset needs; the source
  # is only ever an ownership question, so it uses the cheaper predicate.
  # Every id in the grid, checked once. A cell names two calendars and the same
  # calendar appears in many cells, so the ids are collapsed to a set first —
  # a 5×5 grid is 20 cells but only 5 distinct ownership questions.
  defp validate_cells(user_id, desired) do
    cond do
      Enum.any?(desired, fn {source_id, target_id} -> source_id == target_id end) ->
        {:error, :self_link}

      not all_owned?(user_id, desired) ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  defp all_owned?(user_id, desired) do
    desired
    |> Enum.flat_map(fn {source_id, target_id} -> [source_id, target_id] end)
    |> MapSet.new()
    |> Enum.all?(&CalendarIntegrationQueries.owned_by?(&1, user_id))
  end

  # Keyed by the pair so the diff is a set operation, and carrying the link
  # itself so a deletion does not need a second lookup to find the row.
  defp existing_cells(user_id) do
    user_id
    |> CalendarSyncLinkQueries.list_for_user()
    |> Map.new(&{{&1.source_integration_id, &1.target_integration_id}, &1})
  end

  # A cell can arrive already paused: the grid stages a create and a pause
  # together when a new cell is clicked twice before the save. `enabled` is set
  # on the insert rather than toggled afterwards, so a paused create is one
  # write and never briefly live.
  defp create_cells(user_id, to_create) do
    Enum.reduce_while(to_create, {:ok, 0}, fn {{source_id, target_id}, state}, {:ok, count} ->
      attrs = %{
        "source_integration_id" => source_id,
        "target_integration_id" => target_id,
        "enabled" => state == :active
      }

      case create_link(user_id, attrs) do
        {:ok, _link} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Neither created nor deleted, so it is absent from the summary: the counts
  # report what the save added and removed, and a pause did neither.
  defp toggle_cells(user_id, to_toggle) do
    Enum.reduce_while(to_toggle, :ok, fn {link, enabled?}, :ok ->
      case toggle_enabled(user_id, link.id, enabled?) do
        {:ok, _link} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Reports what was created even when a deletion fails: the creations already
  # happened, and a caller told only about the error would redraw a grid that
  # disagrees with the database.
  defp delete_cells(user_id, to_delete, created) do
    Enum.reduce_while(to_delete, {:ok, %{created: created, deleted: 0}}, fn link,
                                                                            {:ok, summary} ->
      case delete_link(user_id, link.id) do
        {:ok, _link} -> {:cont, {:ok, %{summary | deleted: summary.deleted + 1}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp with_owned_pair(user_id, source_id, target_id, fun) do
    with true <- CalendarIntegrationQueries.owned_by?(source_id, user_id),
         {:ok, target_provider} <-
           CalendarIntegrationQueries.provider_for_owner(target_id, user_id) do
      fun.(target_provider)
    else
      _not_owned -> {:error, :not_found}
    end
  end

  defp owned_link(user_id, link_id) do
    case CalendarSyncLinkQueries.get(link_id) do
      {:ok, %{user_id: ^user_id} = link} -> {:ok, link}
      {:ok, _someone_elses} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # The three fields the caller may not choose: the owner, and the ids the
  # ownership check just validated. Written with string keys because the form
  # params they merge into are string-keyed, and Ecto's cast rejects a map
  # mixing both.
  defp normalise(attrs, user_id, source_id, target_id, target_provider) do
    attrs
    |> stringify_keys()
    |> Map.merge(%{
      "user_id" => user_id,
      "source_integration_id" => source_id,
      "target_integration_id" => target_id,
      "target_provider" => target_provider
    })
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Ids arrive from form params as strings and from code as integers. Anything
  # that is not one of those — including a string with trailing rubbish — is
  # treated as absent, so it reaches the ownership check as `nil` and fails
  # there rather than raising in `String.to_integer/1`.
  defp fetch_id(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> cast_id()
  end

  defp cast_id(id) when is_integer(id), do: id

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _not_an_id -> nil
    end
  end

  defp cast_id(_other), do: nil
end
