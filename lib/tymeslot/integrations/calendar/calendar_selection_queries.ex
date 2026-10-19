defmodule Tymeslot.Integrations.Calendar.CalendarSelectionQueries do
  @moduledoc """
  Writes to an integration's calendar selection (`calendar_list` and the
  `calendar_paths` derived from it) that start from the row as it stands,
  not from a struct read earlier.

  A selection is rewritten whole, so a write built from a stale struct
  reverts whatever changed in between: a calendar the owner ticked while a
  discovery refresh was on the network, or one an availability read
  deselected. Each function here locks the row (`FOR UPDATE`) inside a
  transaction and applies its change to the fresh row.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.RemovedCalendar
  alias Tymeslot.Repo

  @doc """
  Runs `fun` with the integration `id` locked and freshly read (decrypted),
  inside a transaction, and returns what it returns. `fun` answers
  `{:ok, value}` or `{:error, reason}`; an error rolls the transaction back.
  `{:error, :not_found}` when the row is gone, and
  `{:error, :requires_reencryption}` when its credentials cannot be
  decrypted: the integration is still there, so a caller must not treat it
  as removed.
  """
  @spec with_locked(pos_integer(), (CalendarIntegrationSchema.t() ->
                                      {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_locked(id, fun) when is_integer(id) do
    locked(id, &read_decrypted/1, fun)
  end

  @doc """
  As `with_locked/2`, but hands `fun` the row as stored, whether or not its
  credentials still decrypt: for a write that replaces them, such as a
  reconnect, which is how an unreadable row is repaired.
  """
  @spec with_locked_stored(pos_integer(), (CalendarIntegrationSchema.t() ->
                                             {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_locked_stored(id, fun) when is_integer(id) do
    locked(id, &read_stored/1, fun)
  end

  @doc """
  Takes the same row lock as `with_locked_stored/2` inside the caller's
  transaction and answers the row as stored, or `{:error, :not_found}` when it
  is gone. Unlike `with_locked/2` it rolls nothing back, so a caller that
  finds the row gone can go on with the rest of its transaction.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_stored(pos_integer()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def lock_stored(id) when is_integer(id) do
    lock_row(id)
    read_stored(id)
  end

  defp lock_row(id) do
    Repo.one(
      from(ci in CalendarIntegrationSchema,
        where: ci.id == ^id,
        select: ci.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked(id, read, fun) do
    Repo.transaction(fn ->
      lock_row(id)

      with {:ok, fresh} <- read.(id),
           {:ok, value} <- fun.(fresh) do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp read_decrypted(id) do
    case CalendarIntegrationQueries.get(id) do
      {:error, :requires_reencryption, _stale} -> {:error, :requires_reencryption}
      result -> result
    end
  end

  defp read_stored(id) do
    case Repo.get(CalendarIntegrationSchema, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @doc """
  Writes a new selection to `fresh`, the row as `with_locked/2` read it:
  `attrs` carries the `calendar_list` (and `calendar_paths`, when it moves
  with it), and `removed_calendars` the list of calendars the server stopped
  listing, both in one update. Call it from the function passed to
  `with_locked/2`, so the list it starts from is the one it replaces.
  """
  @spec update_selection(CalendarIntegrationSchema.t(), map(), [RemovedCalendar.t()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_selection(%CalendarIntegrationSchema{} = fresh, attrs, removed_calendars) do
    fresh
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Changeset.put_embed(:removed_calendars, removed_calendars)
    |> Repo.update()
  end

  @doc """
  Drops the removed-calendar entries whose ids are in `shown_ids`: the ones
  the owner was shown when they dismissed the notice. An entry recorded
  since is kept, so the owner still sees it. Whether anything was dropped.
  """
  @spec dismiss_removed_calendars(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, boolean()} | {:error, Ecto.Changeset.t() | :not_found}
  def dismiss_removed_calendars(%CalendarIntegrationSchema{id: id}, shown_ids) do
    shown = MapSet.new(shown_ids)

    with_locked_stored(id, fn fresh ->
      case Enum.reject(fresh.removed_calendars, &MapSet.member?(shown, &1.id)) do
        kept when length(kept) == length(fresh.removed_calendars) ->
          {:ok, false}

        kept ->
          fresh
          |> Changeset.change()
          |> Changeset.put_embed(:removed_calendars, kept)
          |> Repo.update()
          |> then(fn
            {:ok, _updated} -> {:ok, true}
            {:error, changeset} -> {:error, changeset}
          end)
      end
    end)
  end
end
