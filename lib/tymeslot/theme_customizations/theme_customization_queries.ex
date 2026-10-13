defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationQueries do
  @moduledoc """
  Query interface for theme customization-related database operations.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Gets the profile's own customization for a theme: the one for its page at
  `/<username>`, never one of its booking pages'.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    query =
      from(tc in ThemeCustomizationSchema,
        where: tc.profile_id == ^profile_id and tc.theme_id == ^theme_id,
        where: is_nil(tc.booking_page_id)
      )

    Repo.one(query)
  end

  @doc """
  Gets a booking page's customization for a theme. The profile id must be the
  one the row belongs to, so another profile's id misses.
  """
  @spec get_by_page_and_theme(integer(), integer(), String.t()) ::
          ThemeCustomizationSchema.t() | nil
  def get_by_page_and_theme(profile_id, page_id, theme_id) do
    Repo.get_by(ThemeCustomizationSchema,
      profile_id: profile_id,
      booking_page_id: page_id,
      theme_id: theme_id
    )
  end

  @doc """
  The profile's own customizations, one per theme it has customised.
  """
  @spec list_for_profile_page(integer()) :: [ThemeCustomizationSchema.t()]
  def list_for_profile_page(profile_id) do
    query =
      from(tc in ThemeCustomizationSchema,
        where: tc.profile_id == ^profile_id and is_nil(tc.booking_page_id)
      )

    Repo.all(query)
  end

  @doc """
  A booking page's customizations.
  """
  @spec list_by_page(integer()) :: [ThemeCustomizationSchema.t()]
  def list_by_page(page_id) do
    query = from(tc in ThemeCustomizationSchema, where: tc.booking_page_id == ^page_id)

    Repo.all(query)
  end

  @doc """
  Gets all theme customizations for a profile.

  Its booking pages' rows carry the profile id too, so they are included:
  `list_for_profile_page/1` returns the profile's own page's rows alone.
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
  Updates the video processing status for a theme customization.
  Returns :ok on success or if the record doesn't exist,
  {:error, :status_update_failed} on update failure.
  """
  @spec update_video_processing_status(integer(), String.t()) ::
          :ok | {:error, :status_update_failed}
  def update_video_processing_status(id, status) do
    case Repo.get(ThemeCustomizationSchema, id) do
      nil ->
        :ok

      record ->
        case record |> Changeset.change(%{video_processing: status}) |> Repo.update() do
          {:ok, _updated} -> :ok
          {:error, _changeset} -> {:error, :status_update_failed}
        end
    end
  end
end
