defmodule Tymeslot.DatabaseQueries.AvailabilityOverrideQueries do
  @moduledoc """
  Query interface for availability override-related database operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.DatabaseSchemas.AvailabilityOverrideSchema
  alias Tymeslot.Repo

  @doc """
  Gets a single availability override.
  Returns nil if the override does not exist.
  """
  @spec get_override(integer()) :: AvailabilityOverrideSchema.t() | nil
  def get_override(id), do: Repo.get(AvailabilityOverrideSchema, id)

  @doc """
  Tagged-tuple variant: returns {:ok, override} | {:error, :not_found}.
  """
  @spec get_override_t(integer()) :: {:ok, AvailabilityOverrideSchema.t()} | {:error, :not_found}
  def get_override_t(id) do
    case get_override(id) do
      nil -> {:error, :not_found}
      o -> {:ok, o}
    end
  end

  @doc """
  Gets an override by profile and date.
  """
  @spec get_override_by_profile_and_date(integer(), Date.t()) ::
          AvailabilityOverrideSchema.t() | nil
  def get_override_by_profile_and_date(profile_id, date) do
    Repo.get_by(AvailabilityOverrideSchema, profile_id: profile_id, date: date)
  end

  @doc """
  Tagged-tuple variant: returns {:ok, override} | {:error, :not_found}.
  """
  @spec get_override_by_profile_and_date_t(integer(), Date.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, :not_found}
  def get_override_by_profile_and_date_t(profile_id, date) do
    case get_override_by_profile_and_date(profile_id, date) do
      nil -> {:error, :not_found}
      o -> {:ok, o}
    end
  end

  @doc """
  Gets all overrides for a profile.
  """
  @spec get_overrides_by_profile(integer()) :: list(AvailabilityOverrideSchema.t())
  def get_overrides_by_profile(profile_id) do
    AvailabilityOverrideSchema
    |> where([o], o.profile_id == ^profile_id)
    |> order_by(asc: :date)
    |> Repo.all()
  end

  @doc """
  Gets overrides for a profile within a date range.
  """
  @spec get_overrides_by_profile_and_date_range(integer(), Date.t(), Date.t()) ::
          list(AvailabilityOverrideSchema.t())
  def get_overrides_by_profile_and_date_range(profile_id, start_date, end_date) do
    AvailabilityOverrideSchema
    |> where([o], o.profile_id == ^profile_id)
    |> where([o], o.date >= ^start_date and o.date <= ^end_date)
    |> order_by(asc: :date)
    |> Repo.all()
  end

  @doc """
  Gets overrides by type for a profile.
  """
  @spec get_overrides_by_profile_and_type(integer(), String.t()) ::
          list(AvailabilityOverrideSchema.t())
  def get_overrides_by_profile_and_type(profile_id, override_type) do
    AvailabilityOverrideSchema
    |> where([o], o.profile_id == ^profile_id and o.override_type == ^override_type)
    |> order_by(asc: :date)
    |> Repo.all()
  end

  @doc """
  Creates an availability override.
  """
  @spec create_override(map()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_override(attrs \\ %{}) when is_map(attrs) do
    %AvailabilityOverrideSchema{}
    |> AvailabilityOverrideSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an availability override.
  """
  @spec update_override(AvailabilityOverrideSchema.t(), map()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_override(%AvailabilityOverrideSchema{} = override, attrs) when is_map(attrs) do
    override
    |> AvailabilityOverrideSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an availability override.
  """
  @spec delete_override(AvailabilityOverrideSchema.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_override(%AvailabilityOverrideSchema{} = override) do
    Repo.delete(override)
  end

  @doc """
  Deletes all overrides for a profile.
  """
  @spec delete_overrides_by_profile(integer()) :: {integer(), nil | [term()]}
  def delete_overrides_by_profile(profile_id) do
    Repo.delete_all(where(AvailabilityOverrideSchema, [o], o.profile_id == ^profile_id))
  end

  @doc """
  Deletes overrides for a profile before a given date.
  """
  @spec delete_overrides_before_date(integer(), Date.t()) :: {integer(), nil | [term()]}
  def delete_overrides_before_date(profile_id, date) do
    Repo.delete_all(
      where(AvailabilityOverrideSchema, [o], o.profile_id == ^profile_id and o.date < ^date)
    )
  end
end
