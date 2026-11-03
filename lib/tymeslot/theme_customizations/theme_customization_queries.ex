defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationQueries do
  @moduledoc """
  Query interface for theme customization-related database operations.
  """
  import Ecto.Query, warn: false

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
  Deletes a booking page's customizations and returns them as they stood when
  deleted.
  """
  @spec delete_by_page(integer()) :: [ThemeCustomizationSchema.t()]
  def delete_by_page(page_id) do
    query =
      from(tc in ThemeCustomizationSchema, where: tc.booking_page_id == ^page_id, select: tc)

    {_count, deleted} = Repo.delete_all(query)
    deleted
  end

  @doc """
  The profile's own customisation of `theme_id` (never one of its booking
  pages'), locked `FOR UPDATE` until the surrounding transaction ends; `nil`
  when there is none.
  """
  @spec lock_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def lock_by_profile_and_theme(profile_id, theme_id) do
    Repo.one(
      from(c in ThemeCustomizationSchema,
        where: c.profile_id == ^profile_id and c.theme_id == ^theme_id,
        where: is_nil(c.booking_page_id),
        lock: "FOR UPDATE"
      )
    )
  end

  @doc """
  A booking page's customisation of `theme_id`, locked as
  `lock_by_profile_and_theme/2` locks the profile's. The profile id must be
  the one the row belongs to, so another profile's id misses.
  """
  @spec lock_by_page_and_theme(integer(), integer(), String.t()) ::
          ThemeCustomizationSchema.t() | nil
  def lock_by_page_and_theme(profile_id, page_id, theme_id) do
    Repo.one(
      from(c in ThemeCustomizationSchema,
        where:
          c.profile_id == ^profile_id and c.booking_page_id == ^page_id and
            c.theme_id == ^theme_id,
        lock: "FOR UPDATE"
      )
    )
  end

  @doc """
  Creates a theme customization, or returns `{:ok, :exists}` without writing
  anything when its profile or booking page already has one for the theme
  (another request created it first).

  No conflict target: the profile's rows and a page's rows each have their own
  unique index, the profile's partial (`booking_page_id IS NULL`), and a bare
  `ON CONFLICT DO NOTHING` covers whichever the row falls under.
  """
  @spec create(map()) ::
          {:ok, ThemeCustomizationSchema.t() | :exists} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    inserted =
      %ThemeCustomizationSchema{}
      |> ThemeCustomizationSchema.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing)

    case inserted do
      {:ok, %ThemeCustomizationSchema{id: nil}} -> {:ok, :exists}
      result -> result
    end
  end

  @doc """
  Updates a theme customization. Callers hold the row's lock
  (`lock_by_profile_and_theme/2`), since the changeset rebuilds the whole
  settings map from `customization`.
  """
  @spec update(ThemeCustomizationSchema.t(), map()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%ThemeCustomizationSchema{} = customization, attrs) do
    customization
    |> ThemeCustomizationSchema.changeset(attrs)
    |> Repo.update()
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

  @doc """
  Records the processing state of the video in `field`, as
  `update_video_processing_status/3` does, but only while `video_path` is
  still the video that field holds. A transcode of a video that has since
  been replaced or removed must not report its outcome against the row.

  Returns `{:error, :replaced}` when the field no longer holds that video, or
  the customisation no longer exists.
  """
  @spec update_video_processing_status_for(integer(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :replaced}
  def update_video_processing_status_for(id, field, video_path, status)
      when is_binary(field) and is_binary(video_path) and status in @video_processing_states do
    query =
      from(c in ThemeCustomizationSchema,
        where: c.id == ^id and fragment("?->>?", c.settings, ^field) == ^video_path,
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
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :replaced}
    end
  end
end
