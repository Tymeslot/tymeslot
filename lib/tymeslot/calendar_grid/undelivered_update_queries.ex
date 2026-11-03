defmodule Tymeslot.CalendarGrid.UndeliveredUpdateQueries do
  @moduledoc """
  Database queries for the guests whose latest update email could not be
  delivered (`Tymeslot.CalendarGrid.UndeliveredUpdateSchema`).
  """

  import Ecto.Query

  alias Tymeslot.CalendarGrid.UndeliveredUpdateSchema
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @conflict_target [:calendar_integration_id, :event_uid, :email]

  @doc """
  Records a failed update email to `email`, or moves the failure already
  recorded for that guest of the event to `failed_at`.
  """
  @spec upsert(pos_integer(), String.t(), String.t(), DateTime.t()) ::
          {:ok, UndeliveredUpdateSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert(calendar_integration_id, event_uid, email, failed_at) do
    %{
      calendar_integration_id: calendar_integration_id,
      event_uid: event_uid,
      email: email,
      failed_at: failed_at
    }
    |> UndeliveredUpdateSchema.changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:failed_at, :updated_at]},
      conflict_target: @conflict_target
    )
  end

  @doc "Deletes the failure recorded for `email` on the event, if any."
  @spec delete(pos_integer(), String.t(), String.t()) :: non_neg_integer()
  def delete(calendar_integration_id, event_uid, email) do
    {count, _rows} =
      UndeliveredUpdateSchema
      |> where([u], u.calendar_integration_id == ^calendar_integration_id)
      |> where([u], u.event_uid == ^event_uid and u.email == ^email)
      |> Repo.delete_all()

    count
  end

  @doc """
  The guests recorded for the event, oldest failure first, provided `user_id`
  owns the integration; none otherwise.
  """
  @spec list_emails_for_owner(pos_integer(), pos_integer(), String.t()) :: [String.t()]
  def list_emails_for_owner(user_id, calendar_integration_id, event_uid) do
    user_id
    |> for_owned_event(calendar_integration_id, event_uid)
    |> order_by([u], asc: u.failed_at, asc: u.id)
    |> select([u], u.email)
    |> Repo.all()
  end

  @doc """
  Deletes every failure recorded for the event, provided `user_id` owns the
  integration; nothing otherwise.
  """
  @spec delete_for_owner(pos_integer(), pos_integer(), String.t()) :: non_neg_integer()
  def delete_for_owner(user_id, calendar_integration_id, event_uid) do
    {count, _rows} =
      user_id
      |> for_owned_event(calendar_integration_id, event_uid)
      |> Repo.delete_all()

    count
  end

  @doc """
  Deletes every failure recorded for the events `event_uids` of the
  integration, provided `user_id` owns it; nothing otherwise.
  """
  @spec delete_events_for_owner(pos_integer(), pos_integer(), [String.t()]) :: non_neg_integer()
  def delete_events_for_owner(_user_id, _calendar_integration_id, []), do: 0

  def delete_events_for_owner(user_id, calendar_integration_id, event_uids) do
    {count, _rows} =
      user_id
      |> for_owned_events(calendar_integration_id, event_uids)
      |> Repo.delete_all()

    count
  end

  @doc """
  Moves the failures recorded on the events `moves` names, provided
  `user_id` owns the integration each comes from, in one transaction: those
  on `from` (an `{integration_id, event_uid}` pair) are put on `to`, or
  deleted when `to` is `nil`. Every failure on a `from` is taken off first,
  so moves that chain (one event's uid becoming another's) do not overwrite
  each other. Returns the number moved or deleted.
  """
  @spec move_for_owner(pos_integer(), [
          {{pos_integer(), String.t()}, {pos_integer(), String.t()} | nil}
        ]) ::
          non_neg_integer()
  def move_for_owner(_user_id, []), do: 0

  def move_for_owner(user_id, moves) do
    targets = Map.new(moves)

    {:ok, count} =
      Repo.transaction(fn ->
        found = owned_failures_on(user_id, Map.keys(targets))

        Repo.delete_all(
          from(u in UndeliveredUpdateSchema, where: u.id in ^Enum.map(found, & &1.id))
        )

        Repo.insert_all(UndeliveredUpdateSchema, moved_rows(found, targets),
          on_conflict: {:replace, [:failed_at, :updated_at]},
          conflict_target: @conflict_target
        )

        length(found)
      end)

    count
  end

  defp owned_failures_on(user_id, events) do
    events
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {integration_id, uids} ->
      Repo.all(for_owned_events(user_id, integration_id, uids))
    end)
  end

  # Each failure put on its event's successor, one per guest of an event.
  defp moved_rows(found, targets) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    found
    |> Enum.map(&{Map.fetch!(targets, {&1.calendar_integration_id, &1.event_uid}), &1})
    |> Enum.reject(fn {to, _failure} -> is_nil(to) end)
    |> Enum.uniq_by(fn {to, failure} -> {to, failure.email} end)
    |> Enum.map(fn {{integration_id, uid}, failure} ->
      %{
        calendar_integration_id: integration_id,
        event_uid: uid,
        email: failure.email,
        failed_at: failure.failed_at,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp for_owned_event(user_id, calendar_integration_id, event_uid),
    do: for_owned_events(user_id, calendar_integration_id, [event_uid])

  defp for_owned_events(user_id, calendar_integration_id, event_uids) do
    owned =
      from(i in CalendarIntegrationSchema,
        where: i.id == ^calendar_integration_id and i.user_id == ^user_id,
        select: i.id
      )

    from(u in UndeliveredUpdateSchema,
      where: u.calendar_integration_id in subquery(owned) and u.event_uid in ^event_uids
    )
  end
end
