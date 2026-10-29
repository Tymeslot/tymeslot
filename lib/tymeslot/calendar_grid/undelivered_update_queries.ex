defmodule Tymeslot.CalendarGrid.UndeliveredUpdateQueries do
  @moduledoc """
  Database queries for the guests whose latest update email could not be
  delivered (`Tymeslot.CalendarGrid.UndeliveredUpdateSchema`).
  """

  import Ecto.Query

  alias Tymeslot.CalendarGrid.UndeliveredUpdateSchema
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

  defp for_owned_event(user_id, calendar_integration_id, event_uid) do
    owned =
      from(i in CalendarIntegrationSchema,
        where: i.id == ^calendar_integration_id and i.user_id == ^user_id,
        select: i.id
      )

    from(u in UndeliveredUpdateSchema,
      where: u.calendar_integration_id in subquery(owned) and u.event_uid == ^event_uid
    )
  end
end
