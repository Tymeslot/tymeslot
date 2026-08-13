defmodule Tymeslot.Integrations.Calendar.SyncLink.ConflictHistory do
  @moduledoc """
  The organiser-facing read of the conflict audit, and the authorisation that
  has to sit in front of it.

  `CalendarSyncConflictQueries` is not user-scoped: `list_for_link/2` takes an
  integer and answers for whatever link carries it. What it answers with is not
  innocuous — a conflict row names the source event's UID and the times two of
  the organiser's calendars diverged — so a LiveView calling the query module
  directly would hand the browser another organiser's history for the price of
  guessing an id.

  The check follows `SyncLink`'s own `owned_link/2` exactly, including its
  answer: `{:error, :not_found}` rather than `:forbidden`, so a forged id cannot
  be used to discover which ids exist. It is a separate module from `SyncLink`
  only because that module is the write side's home and this is a read; the rule
  it enforces is the same rule, stated once more where it applies.

  ## Why the panel's own read is a different function

  `recent_for_user/2` answers for every link at once, and derives the ids it
  reads from the acting user rather than being handed them — which is what makes
  it safe without a per-row check. The dashboard renders each of an organiser's
  links with its history beneath it, so asking per link would issue one query
  per row and re-answer an ownership question the listing has already settled.

  `for_link/3` is the narrower case: one link, named by a parameter that arrived
  from a browser and therefore cannot be trusted. That one is checked.

  Neither function holds a `Repo` call. The queries live in
  `CalendarSyncConflictQueries` with the rest of the table's data access; what
  is here is the rule about who may ask.
  """

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  @doc """
  One link's recent conflicts, newest first, once the acting user is shown to
  own the link.
  """
  @spec for_link(integer(), integer() | any(), keyword()) ::
          {:ok, [CalendarSyncConflictSchema.t()]} | {:error, :not_found}
  def for_link(user_id, link_id, opts \\ []) when is_integer(user_id) do
    case CalendarSyncLinkQueries.get(link_id) do
      {:ok, %CalendarSyncLinkSchema{user_id: ^user_id, id: id}} ->
        {:ok, Map.get(CalendarSyncConflictQueries.list_for_links([id], opts), id, [])}

      {:ok, _someone_elses} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Every conflict recorded against this organiser's links, keyed by link id and
  newest first within each.

  Links that have never conflicted are absent rather than present with an empty
  list: the panel renders a history section only where there is one, and a key
  whose value is `[]` would make the caller ask twice.
  """
  @spec recent_for_user(integer(), keyword()) :: %{
          optional(integer()) => [CalendarSyncConflictSchema.t()]
        }
  def recent_for_user(user_id, opts \\ []) when is_integer(user_id) do
    user_id
    |> CalendarSyncConflictQueries.link_ids_for_user()
    |> CalendarSyncConflictQueries.list_for_links(opts)
  end
end
