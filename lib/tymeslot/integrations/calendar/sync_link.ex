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

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
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
  a series of creates: cells newly ticked become links, cells cleared become
  deletions, and — the rule the rest of this function exists to protect — cells
  that did not move are not touched at all.

  That last one is not an optimisation. Recreating an unchanged link means
  deleting it first, and `delete_link/2` withdraws every placeholder it has
  written from the provider on its way out. A save that rebuilt the whole grid
  would therefore tear down and rewrite every mirror in the set, turning a
  no-op into a burst of provider writes and leaving the organiser's other
  calendars briefly empty of the busy blocks that are the entire point.

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

  Cells are `{source_integration_id, target_integration_id}` tuples. Anything
  already linked but absent from the list is deleted, which is what makes
  clearing a row of the grid work.
  """
  @spec apply_matrix(integer(), [{integer(), integer()}]) ::
          {:ok, %{created: non_neg_integer(), deleted: non_neg_integer()}}
          | {:error, :not_found | :self_link | term()}
  def apply_matrix(user_id, cells) when is_integer(user_id) and is_list(cells) do
    desired = MapSet.new(cells)

    with :ok <- validate_cells(user_id, desired) do
      existing = existing_cells(user_id)

      to_create = MapSet.difference(desired, MapSet.new(Map.keys(existing)))
      to_delete = for {pair, link} <- existing, not MapSet.member?(desired, pair), do: link

      with {:ok, created} <- create_cells(user_id, to_create) do
        delete_cells(user_id, to_delete, created)
      end
    end
  end

  @doc """
  Edits an existing link.

  The target may move, so ownership is re-verified against the target the
  attributes ask for rather than the one already stored, and the provider
  handed to the changeset is that new target's.
  """
  @spec update_link(integer(), integer() | any(), map()) :: result()
  def update_link(user_id, link_id, attrs) when is_integer(user_id) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      source_id = fetch_id(attrs, :source_integration_id) || link.source_integration_id
      target_id = fetch_id(attrs, :target_integration_id) || link.target_integration_id

      with_owned_pair(user_id, source_id, target_id, fn target_provider ->
        CalendarSyncLinkQueries.update(
          link,
          normalise(attrs, user_id, source_id, target_id, target_provider)
        )
      end)
    end
  end

  @doc """
  Pauses or resumes one link.

  Pausing leaves the placeholders already written on the target in place; only
  deleting the link tears the mapping rows down. Routed through `update_link/3`
  so a paused link is re-validated against its target's provider — an
  integration reconnected as a subscription while a link pointed at it should
  not be resumable.
  """
  @spec toggle_enabled(integer(), integer() | any(), boolean()) :: result()
  def toggle_enabled(user_id, link_id, enabled) when is_boolean(enabled) do
    with {:ok, link} <- owned_link(user_id, link_id) do
      link
      |> CalendarSyncLinkSchema.enabled_changeset(enabled)
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
  A changeset for the dashboard form, carrying the target's provider so the
  form re-renders under the same rules the write will apply.
  """
  @spec change_link(CalendarSyncLinkSchema.t(), map()) :: Ecto.Changeset.t()
  def change_link(%CalendarSyncLinkSchema{} = link, attrs \\ %{}),
    do: CalendarSyncLinkQueries.change(link, attrs)

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

  defp create_cells(user_id, to_create) do
    Enum.reduce_while(to_create, {:ok, 0}, fn {source_id, target_id}, {:ok, count} ->
      attrs = %{
        "source_integration_id" => source_id,
        "target_integration_id" => target_id
      }

      case create_link(user_id, attrs) do
        {:ok, _link} -> {:cont, {:ok, count + 1}}
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
