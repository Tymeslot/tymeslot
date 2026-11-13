defmodule Tymeslot.Availability.BookabilityOverrideQueries do
  @moduledoc """
  Data access for `event_bookability_overrides`.
  """

  import Ecto.Query

  alias Tymeslot.Availability.BookabilityOverrideSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  # Kept well under PostgreSQL's 65,535 bind-parameter limit.
  @chunk_size 1000

  @doc "Stores the choice for one event, replacing any earlier one."
  @spec upsert(integer(), integer(), String.t(), boolean()) ::
          {:ok, BookabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert(user_id, integration_id, uid, busy?) do
    %BookabilityOverrideSchema{}
    |> BookabilityOverrideSchema.changeset(%{
      user_id: user_id,
      calendar_integration_id: integration_id,
      provider_uid: uid,
      busy: busy?
    })
    |> Repo.insert(
      on_conflict: {:replace, [:busy, :updated_at]},
      conflict_target: [:user_id, :calendar_integration_id, :provider_uid],
      returning: true
    )
  end

  @doc "Removes the choice for one event, if there is one."
  @spec delete(integer(), integer(), String.t()) :: :ok
  def delete(user_id, integration_id, uid) do
    BookabilityOverrideSchema
    |> where(
      [o],
      o.user_id == ^user_id and o.calendar_integration_id == ^integration_id and
        o.provider_uid == ^uid
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Deletes the choices made on the events `uids` of the integration
  `integration_id` that no cached row of the integration carries any more,
  and returns how many went.

  Called with the uids of cached rows just removed because their event is
  gone: deleted from the calendar, dropped from a feed, or deleted here.
  Never call it for rows that are merely absent (a failed or partial read,
  a calendar the organiser deselected), since the organiser still expects
  those choices. Matched on the uid alone, never on a date: a recurring
  event keeps one choice for all its occurrences, and a row put straight
  back (a full refresh deletes and reinserts) keeps its choice.
  """
  @spec delete_orphaned(integer(), [String.t()]) :: non_neg_integer()
  def delete_orphaned(_integration_id, []), do: 0

  def delete_orphaned(integration_id, uids) do
    uids
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce(0, fn chunk, total ->
      {count, _rows} =
        Repo.delete_all(
          from(o in BookabilityOverrideSchema,
            as: :override,
            where: o.calendar_integration_id == ^integration_id and o.provider_uid in ^chunk,
            where: not exists(cached_event())
          )
        )

      total + count
    end)
  end

  defp cached_event do
    from(e in ProviderCalendarEventSchema,
      where:
        e.calendar_integration_id == parent_as(:override).calendar_integration_id and
          e.uid == parent_as(:override).provider_uid,
      select: 1
    )
  end

  @doc "Every choice the user has made."
  @spec list_for_user(integer()) :: [BookabilityOverrideSchema.t()]
  def list_for_user(user_id) do
    BookabilityOverrideSchema
    |> where([o], o.user_id == ^user_id)
    |> Repo.all()
  end
end
