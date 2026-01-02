defmodule Tymeslot.DatabaseQueries.ProfileQueries do
  @moduledoc """
  Database queries for user profiles.
  """

  import Ecto.Query
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.DatabaseSchemas.{MeetingTypeSchema, ProfileSchema}
  alias Tymeslot.Repo

  @doc """
  Creates a profile for a user ID.
  """
  @spec create_profile(integer()) :: {:ok, ProfileSchema.t()} | {:error, term()}
  def create_profile(user_id) do
    Repo.transaction(fn ->
      with {:ok, profile} <-
             %ProfileSchema{user_id: user_id}
             |> ProfileSchema.changeset(%{})
             |> Repo.insert(),
           {:ok, _} <- WeeklySchedule.create_default_weekly_schedule(profile.id) do
        Repo.preload(profile, :user)
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, _} -> Repo.rollback("Failed to create default availability")
        other -> Repo.rollback(other)
      end
    end)
  end

  @doc """
  Gets a profile by user ID, creating one if it doesn't exist.
  """
  @spec get_or_create_by_user_id(integer()) :: {:ok, ProfileSchema.t()} | {:error, term()}
  def get_or_create_by_user_id(user_id) do
    case get_by_user_id(user_id) do
      {:error, :not_found} ->
        create_profile(user_id)

      {:ok, profile} ->
        {:ok, profile}
    end
  end

  @doc """
  Gets a profile by user ID.
  Returns {:ok, profile} if found, {:error, :not_found} otherwise.
  """
  @spec get_by_user_id(integer()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_user_id(user_id) do
    case ProfileSchema
         |> where([p], p.user_id == ^user_id)
         |> preload(:user)
         |> Repo.one() do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Gets a profile by profile ID, raising if not found.
  Preloads the associated user for convenience.
  """
  @spec get_profile!(integer()) :: ProfileSchema.t()
  def get_profile!(profile_id) when is_integer(profile_id) do
    ProfileSchema
    |> Repo.get!(profile_id)
    |> Repo.preload(:user)
  end

  @doc """
  Updates a profile.
  """
  @spec update_profile(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%ProfileSchema{} = profile, attrs) do
    result =
      profile
      |> ProfileSchema.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_profile} = result ->
        # Log successful update for debugging
        require Logger

        Logger.info(
          "Profile updated successfully: user_id=#{updated_profile.user_id}, timezone=#{updated_profile.timezone}"
        )

        result

      error ->
        error
    end
  end

  @doc """
  Gets a profile with preloaded user.
  """
  @spec get_with_user(integer()) :: ProfileSchema.t() | nil
  def get_with_user(profile_id) do
    ProfileSchema
    |> where([p], p.id == ^profile_id)
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Updates a specific field in the profile.
  """
  @spec update_field(ProfileSchema.t(), atom(), term()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_field(%ProfileSchema{} = profile, field, value) do
    profile
    |> ProfileSchema.changeset(%{field => value})
    |> Repo.update()
  end

  @doc """
  Gets a profile by username.
  Returns {:ok, profile} if found, {:error, :not_found} otherwise.
  """
  @spec get_by_username(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_username(username) when is_binary(username) do
    case Repo.get_by(ProfileSchema, username: username) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Checks if a username is available.
  """
  @spec username_available?(String.t()) :: boolean()
  def username_available?(username) when is_binary(username) do
    case get_by_username(username) do
      {:error, :not_found} -> true
      {:ok, _} -> false
    end
  end

  @doc """
  Updates a profile's username.
  """
  @spec update_username(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_username(%ProfileSchema{} = profile, username) do
    update_profile(profile, %{username: username})
  end

  @doc """
  Creates a profile within a transaction.

  This function accepts a repo argument to ensure it runs within the same
  transaction as other operations. Used by OAuth user creation to prevent
  race conditions.

  ## Parameters
  - repo: The Ecto repo to use (typically passed from Ecto.Multi)
  - attrs: Profile attributes including user_id

  ## Returns
  - {:ok, profile} on success
  - {:error, changeset} on failure
  """
  @spec create_profile_in_transaction(Ecto.Repo.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_profile_in_transaction(repo, attrs) when is_map(attrs) do
    %ProfileSchema{}
    |> ProfileSchema.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Preloads a profile with its associated user.
  """
  @spec preload_user(ProfileSchema.t()) :: ProfileSchema.t()
  def preload_user(%ProfileSchema{} = profile) do
    Repo.preload(profile, :user)
  end

  @doc """
  Preloads associations for a profile.

  ## Parameters
  - profile: The profile struct
  - associations: An atom or list of atoms representing the associations to preload

  ## Returns
  - The profile with preloaded associations
  """
  @spec preload_associations(ProfileSchema.t(), atom() | [atom()]) :: ProfileSchema.t()
  def preload_associations(%ProfileSchema{} = profile, associations) do
    Repo.preload(profile, associations)
  end

  @spec preload_associations(nil, any()) :: nil
  def preload_associations(nil, _associations), do: nil

  @doc """
  Updates a profile's avatar filename.
  """
  @spec update_avatar(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_avatar(%ProfileSchema{} = profile, filename) do
    changeset = ProfileSchema.changeset(profile, %{avatar: filename})
    Repo.update(changeset)
  end

  @doc """
  Removes avatar from profile (sets to nil).
  """
  @spec remove_avatar(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def remove_avatar(%ProfileSchema{} = profile) do
    changeset = ProfileSchema.changeset(profile, %{avatar: nil})
    Repo.update(changeset)
  end

  @doc """
  Gets a profile by username with preloaded user and meeting types in a single query.
  This optimizes the organizer context resolution by avoiding multiple queries.
  Returns {:ok, profile} with :user and :meeting_types preloaded, or {:error, :not_found} if not found.
  """
  @spec get_by_username_with_context(String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_username_with_context(username) when is_binary(username) do
    # Use a single query with preloading to avoid N+1
    query =
      from(p in ProfileSchema,
        where: p.username == ^username,
        preload: [:user]
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      profile ->
        # Load meeting types in a single query and attach to profile
        meeting_types_query =
          from(mt in MeetingTypeSchema,
            where: mt.user_id == ^profile.user_id and mt.is_active == true,
            order_by: [asc: mt.sort_order, asc: mt.name]
          )

        meeting_types = Repo.all(meeting_types_query)
        # Add meeting_types as a virtual field
        result = Map.put(profile, :meeting_types, meeting_types)
        {:ok, result}
    end
  end

  @doc """
  Sets the primary calendar integration for a user within a transaction.
  This ensures data consistency when updating the profile and clearing other integrations.
  """
  @spec set_primary_calendar_integration_transactional(integer(), integer(), function()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def set_primary_calendar_integration_transactional(user_id, integration_id, clear_others_fn) do
    Repo.transaction(fn ->
      with {:ok, profile} <- get_by_user_id(user_id),
           :ok <- run_clear_fun(clear_others_fn),
           {:ok, updated_profile} <-
             update_profile(profile, %{primary_calendar_integration_id: integration_id}) do
        updated_profile
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp run_clear_fun(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  @doc """
  Clears the primary calendar integration for a user when no calendars remain.
  """
  @spec clear_primary_calendar_integration(integer()) ::
          {:ok, ProfileSchema.t()} | {:error, term()}
  def clear_primary_calendar_integration(user_id) do
    case get_by_user_id(user_id) do
      {:ok, profile} ->
        update_profile(profile, %{primary_calendar_integration_id: nil})

      error ->
        error
    end
  end
end
