defmodule Tymeslot.DatabaseQueries.ThemeCustomizationQueries do
  @moduledoc """
  Query interface for theme customization-related database operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Repo

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    Repo.get_by(ThemeCustomizationSchema, profile_id: profile_id, theme_id: theme_id)
  end

  @doc """
  Tagged-tuple variant: returns {:ok, customization} | {:error, :not_found}.
  """
  @spec get_by_profile_and_theme_t(integer(), String.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, :not_found}
  def get_by_profile_and_theme_t(profile_id, theme_id) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil -> {:error, :not_found}
      customization -> {:ok, customization}
    end
  end

  @doc """
  Gets all theme customizations for a profile.
  """
  @spec get_all_by_profile_id(integer()) :: [ThemeCustomizationSchema.t()]
  def get_all_by_profile_id(profile_id) do
    ThemeCustomizationSchema
    |> where([tc], tc.profile_id == ^profile_id)
    |> Repo.all()
  end

  @doc """
  Creates a theme customization.
  """
  @spec create(map()) :: {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %ThemeCustomizationSchema{}
    |> ThemeCustomizationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a theme customization.
  """
  @spec update(ThemeCustomizationSchema.t(), map()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%ThemeCustomizationSchema{} = customization, attrs) do
    customization
    |> ThemeCustomizationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a theme customization.
  """
  @spec delete(ThemeCustomizationSchema.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%ThemeCustomizationSchema{} = customization) do
    Repo.delete(customization)
  end

  @doc """
  Gets a profile by user_id.
  Used for finding profile when given a user_id.
  """
  @spec get_profile_by_user_id(integer()) :: ProfileSchema.t() | nil
  def get_profile_by_user_id(user_id) do
    Repo.get_by(ProfileSchema, user_id: user_id)
  end

  @doc """
  Tagged-tuple variant: returns {:ok, profile} | {:error, :not_found}.
  """
  @spec get_profile_by_user_id_t(integer()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_profile_by_user_id_t(user_id) do
    case get_profile_by_user_id(user_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end
end
