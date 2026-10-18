defmodule Tymeslot.Availability.BookabilityOverrideQueries do
  @moduledoc """
  Data access for `event_bookability_overrides`.
  """

  import Ecto.Query

  alias Tymeslot.Availability.BookabilityOverrideSchema
  alias Tymeslot.Repo

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

  @doc "Every choice the user has made."
  @spec list_for_user(integer()) :: [BookabilityOverrideSchema.t()]
  def list_for_user(user_id) do
    BookabilityOverrideSchema
    |> where([o], o.user_id == ^user_id)
    |> Repo.all()
  end
end
