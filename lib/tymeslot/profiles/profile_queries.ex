defmodule Tymeslot.Profiles.ProfileQueries do
  @moduledoc """
  Database queries for user profiles.
  """

  import Ecto.Query
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  @doc """
  Inserts a new profile record for a user ID.
  Returns the profile with its user preloaded.
  """
  @spec insert_profile(integer()) :: {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_profile(user_id) do
    result =
      %ProfileSchema{}
      |> ProfileSchema.create_changeset(%{user_id: user_id})
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
    hash = Token.hash_token(token)

    from(p in ProfileSchema, where: p.freebusy_token_hash == ^hash, preload: [:user])
    |> owner_not_pending_deletion()
    |> Repo.one()
    |> found()
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
  Updates the booking page's introductory text and its on/off switch.
  """
  @spec update_booking_text(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_booking_text(%ProfileSchema{} = profile, attrs) do
    profile
    |> ProfileSchema.booking_text_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the organiser's headline and bio.
  """
  @spec update_intro(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_intro(%ProfileSchema{} = profile, attrs) do
    profile
    |> ProfileSchema.intro_changeset(attrs)
    |> Repo.update()
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

  @doc "Updates the host's name or time zone."
  @spec update_basic(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_basic(%ProfileSchema{} = profile, attrs),
    do: profile |> ProfileSchema.basic_changeset(attrs) |> Repo.update()

  @doc "Updates the name and avatar together."
  @spec update_identity(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_identity(%ProfileSchema{} = profile, attrs),
    do: profile |> ProfileSchema.identity_changeset(attrs) |> Repo.update()

  @doc "Updates the booking theme fields."
  @spec update_theme(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_theme(%ProfileSchema{} = profile, attrs),
    do: profile |> ProfileSchema.theme_changeset(attrs) |> Repo.update()

  @doc "Replaces the sites allowed to embed the booking page."
  @spec update_embed_domains(ProfileSchema.t(), [String.t()]) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_embed_domains(%ProfileSchema{} = profile, domains),
    do:
      profile
      |> ProfileSchema.embed_domains_changeset(%{allowed_embed_domains: domains})
      |> Repo.update()

  @doc "Updates the account-wide booking limits."
  @spec update_booking_limits(ProfileSchema.t(), map()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_booking_limits(%ProfileSchema{} = profile, attrs),
    do: profile |> ProfileSchema.booking_limits_changeset(attrs) |> Repo.update()

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
  The id of the user owning a profile, or nil when there is no such profile.
  Keyed by *profile* id, like `get_with_user/1`.
  """
  @spec user_id_for_profile(integer() | nil) :: integer() | nil
  def user_id_for_profile(nil), do: nil

  def user_id_for_profile(profile_id) do
    ProfileSchema
    |> where([p], p.id == ^profile_id)
    |> select([p], p.user_id)
    |> Repo.one()
  end

  @doc """
  Gets a profile by username.
  Returns {:ok, profile} if found, {:error, :not_found} otherwise.

  Matched exactly. Which handle resolves which booking page is a routing
  decision, so this lookup and `get_by_username_with_user/1` deliberately do
  not fold case; `username_available?/1` does, because it answers a different
  question.

  A host whose account is pending deletion is not found: their public pages
  answer as if they did not exist.
  """
  @spec get_by_username(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_username(username) when is_binary(username) do
    from(p in ProfileSchema, where: p.username == ^username)
    |> owner_not_pending_deletion()
    |> Repo.one()
    |> found()
  end

  @doc """
  Checks if a username is available.

  Asked the way the database answers it: the unique index behind `username`
  is on `lower(username)`, so a row stored as `JohnSmith` makes `johnsmith`
  taken. An exact-match lookup would call it free and leave the collision for
  the insert to discover, one round trip after the live check could have said
  so. Only rows written outside the changeset can be non-lowercase, which is
  exactly the case the functional index exists to catch.
  """
  @spec username_available?(String.t()) :: boolean()
  def username_available?(username) when is_binary(username) do
    normalised = String.downcase(username)

    not Repo.exists?(
      from(p in ProfileSchema, where: fragment("lower(?)", p.username) == ^normalised)
    )
  end

  @doc """
  Updates a profile's username.
  """
  @spec update_username(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_username(%ProfileSchema{} = profile, username),
    do: profile |> ProfileSchema.username_changeset(%{username: username}) |> Repo.update()

  @doc """
  Gives a profile `username` only if its stored username is still blank,
  deciding from the row, locked, rather than from `profile`, which may be
  stale (a username chosen in another tab since it was read).

  `{:unchanged, stored}` when the stored row already has a username, with
  the row as stored; `{:error, :not_found}` when the profile has been
  deleted since it was read.
  """
  @spec update_username_if_blank(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()}
          | {:unchanged, ProfileSchema.t()}
          | {:error, Ecto.Changeset.t() | :not_found}
  def update_username_if_blank(%ProfileSchema{id: id}, username) do
    result =
      Repo.transaction(fn ->
        case Repo.one(from(p in ProfileSchema, where: p.id == ^id, lock: "FOR UPDATE")) do
          nil -> Repo.rollback(:not_found)
          stored -> fill_blank_username(stored, username)
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  defp fill_blank_username(%ProfileSchema{username: blank} = stored, username)
       when blank in [nil, ""] do
    case update_username(stored, username) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fill_blank_username(stored, _username), do: {:unchanged, stored}

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
    |> ProfileSchema.create_changeset(attrs)
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
    profile |> ProfileSchema.avatar_changeset(%{avatar: filename}) |> Repo.update()
  end

  @doc """
  Removes avatar from profile (sets to nil).
  """
  @spec remove_avatar(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def remove_avatar(%ProfileSchema{} = profile) do
    profile |> ProfileSchema.avatar_changeset(%{avatar: nil}) |> Repo.update()
  end

  @doc """
  Gets a profile by username with preloaded user.
  Returns {:ok, profile} or {:error, :not_found}.
  """
  @spec get_by_username_with_user(String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, :not_found}
  def get_by_username_with_user(username) when is_binary(username) do
    from(p in ProfileSchema, where: p.username == ^username, preload: [:user])
    |> owner_not_pending_deletion()
    |> Repo.one()
    |> found()
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
        update_primary_calendar(profile, integration_id)

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
        update_primary_calendar(profile, nil)

      error ->
        error
    end
  end

  defp update_primary_calendar(profile, integration_id) do
    profile
    |> ProfileSchema.primary_calendar_changeset(%{
      primary_calendar_integration_id: integration_id
    })
    |> Repo.update()
  end

  # A host whose account waits to be deleted is frozen: every public lookup
  # by username or feed token answers as if the profile did not exist.
  defp owner_not_pending_deletion(query) do
    from(p in query, join: u in assoc(p, :user), where: is_nil(u.deletion_scheduled_at))
  end

  defp found(nil), do: {:error, :not_found}
  defp found(profile), do: {:ok, profile}
end
