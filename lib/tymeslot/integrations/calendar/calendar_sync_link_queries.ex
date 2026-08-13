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
