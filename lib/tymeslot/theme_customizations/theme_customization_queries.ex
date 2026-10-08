defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationQueries do
  @moduledoc """
  Query interface for theme customization-related database operations.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    Repo.get_by(ThemeCustomizationSchema, profile_id: profile_id, theme_id: theme_id)
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

  @video_processing_states ~w(pending completed failed)

  @doc """
  Records the processing state of the video in the asset field `field`
  (`"background_video_path"`) of a theme customisation, leaving every other
  field's state as it is, and returns the updated customisation. The state
  is merged into the stored map by the one `UPDATE`, so two transcodes of
  one customisation finishing together never overwrite each other.
  `{:error, :not_found}` when the customisation no longer exists.
  """
  @spec update_video_processing_status(integer(), String.t(), String.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, :not_found}
  def update_video_processing_status(id, field, status)
      when is_binary(field) and status in @video_processing_states do
    query =
      from(c in ThemeCustomizationSchema,
        where: c.id == ^id,
        select: c,
        update: [
          set: [
            video_processing_status:
              fragment(
                "? || jsonb_build_object(?::text, ?::text)",
                c.video_processing_status,
                ^field,
                ^status
              ),
            updated_at: ^DateTime.utc_now(:second)
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [customization]} -> {:ok, customization}
      {0, []} -> {:error, :not_found}
    end
  end
end
