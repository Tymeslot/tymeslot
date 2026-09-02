defmodule Tymeslot.Profiles.ProfileQueries do
  @moduledoc """
  Database queries for user profiles.
  """

  import Ecto.Query
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Inserts a new profile record for a user ID.
  Returns the profile with its user preloaded.
  """
  @spec insert_profile(integer()) :: {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_profile(user_id) do
    result =
      %ProfileSchema{user_id: user_id}
      |> ProfileSchema.changeset(%{})
      |> Repo.insert()

    case result do
      {:ok, profile} -> {:ok, Repo.preload(profile, :user)}
      error -> error
    end
  end

  @doc """
  Fetches the profile owning the given free/busy feed token.
  """
  @spec get_by_freebusy_token(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_freebusy_token(token) when is_binary(token) and token != "" do
    case Repo.get_by(ProfileSchema, freebusy_token: token) do
      nil -> {:error, :not_found}
      profile -> {:ok, Repo.preload(profile, :user)}
    end
  end

  def get_by_freebusy_token(_other), do: {:error, :not_found}

  @doc """
  Sets (or clears, with `nil`) the profile's free/busy feed token.
  """
  @spec update_freebusy_token(ProfileSchema.t(), String.t() | nil) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_freebusy_token(%ProfileSchema{} = profile, token) do
    profile
    |> ProfileSchema.freebusy_token_changeset(%{freebusy_token: token})
    |> Repo.update()
  end

  @doc """
  Fetches the profile owning the given booking API token.
  """
  @spec get_by_booking_api_token(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_booking_api_token(token) when is_binary(token) and token != "" do
    case Repo.get_by(ProfileSchema, booking_api_token: token) do
      nil -> {:error, :not_found}
      profile -> {:ok, Repo.preload(profile, :user)}
    end
  end

  def get_by_booking_api_token(_other), do: {:error, :not_found}

  @doc """
  Sets (or clears, with `nil`) the profile's booking API token.
  """
  @spec update_booking_api_token(ProfileSchema.t(), String.t() | nil) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_booking_api_token(%ProfileSchema{} = profile, token) do
    profile
    |> ProfileSchema.booking_api_token_changeset(%{booking_api_token: token})
    |> Repo.update()
  end

  @doc """
  Gets a profile by user ID, creating one if it doesn't exist.
  Note: The caller is responsible for any post-creation side effects
  (e.g. creating default weekly schedules).
  """
  @spec get_or_create_by_user_id(integer()) :: {:ok, ProfileSchema.t()} | {:error, term()}
  def get_or_create_by_user_id(user_id) do
    case get_by_user_id(user_id) do
      {:error, :not_found} ->
        insert_profile(user_id)

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
  Updates a profile.
  """
  @spec update_profile(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%ProfileSchema{} = profile, attrs) do
    profile
    |> ProfileSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically stamps `booking_page_published_at` for a profile, but only when it
  is currently `nil`.

  The `is_nil` guard makes the update race-safe and idempotent: the timestamp is
  written by exactly one caller. Returns the number of rows actually updated
  (`1` on first publish, `0` if it was already set).
  """
  @spec mark_booking_page_published(integer(), DateTime.t()) :: non_neg_integer()
  def mark_booking_page_published(profile_id, published_at) do
    {count, _result} =
      ProfileSchema
      |> where([p], p.id == ^profile_id and is_nil(p.booking_page_published_at))
      |> Repo.update_all(set: [booking_page_published_at: published_at])

    count
  end

  @doc """
  Gets a profile with preloaded user.

  Keyed by *profile* id. `get_by_user_id/1` is the user-keyed lookup, and
  `Tymeslot.Profiles.get_profile/1` on the context in front of this module is
  user-keyed too: the two ids are not interchangeable.
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
      {:ok, _result} -> false
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
  Gets a profile by user ID within a transaction.

  Accepts a repo argument so the lookup participates in the same transaction
  as its callers, ensuring it sees uncommitted parent-transaction state.

  Returns `{:ok, profile}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_user_id_in_transaction(Ecto.Repo.t(), integer()) ::
          {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_user_id_in_transaction(repo, user_id) do
    case repo.one(from(p in ProfileSchema, where: p.user_id == ^user_id)) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
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
  Gets a profile by username with preloaded user.
  Returns {:ok, profile} or {:error, :not_found}.
  """
  @spec get_by_username_with_user(String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_username_with_user(username) when is_binary(username) do
    query =
      from(p in ProfileSchema,
        where: p.username == ^username,
        preload: [:user]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Sets the primary calendar integration for a user's profile.
  Updates only the `primary_calendar_integration_id` field.
  """
  @spec set_primary_calendar_integration(integer(), integer()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def set_primary_calendar_integration(user_id, integration_id) do
    case get_by_user_id(user_id) do
      {:ok, profile} ->
        update_profile(profile, %{primary_calendar_integration_id: integration_id})

      error ->
        error
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
