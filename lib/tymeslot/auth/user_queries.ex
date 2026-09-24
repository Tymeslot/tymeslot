defmodule Tymeslot.Auth.UserQueries do
  @moduledoc """
  Queries over the `users` table for accounts and credentials: lookups by id,
  email and provider identity, account creation, password, locale and activity
  writes, and email availability checks.

  Admin-role queries live in `Tymeslot.Auth.AdminUserQueries`; onboarding
  writes in `Tymeslot.Onboarding.OnboardingQueries`.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo

  @doc """
  Gets a single user.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user(integer()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user(id) do
    case Repo.get(UserSchema, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a single user and locks their row (`FOR UPDATE`) until the enclosing
  transaction ends. Must be called inside `Repo.transaction/1`.
  """
  @spec get_user_for_update(integer()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_for_update(id) do
    case Repo.one(from(u in UserSchema, where: u.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a single user with the profile preloaded.

  Same contract as `get_user/1`. Used by the email worker handlers, which need
  `profile.full_name` to greet the recipient by name.
  """
  @spec get_user_with_profile(integer()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_with_profile(id) do
    case Repo.get(UserSchema, id) do
      nil -> {:error, :not_found}
      user -> {:ok, Repo.preload(user, :profile)}
    end
  end

  @doc """
  Gets a user by email.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec get_user_by_email(String.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_email(email, repo \\ Repo) when is_binary(email) do
    normalised = email |> String.trim() |> String.downcase()

    case repo.get_by(UserSchema, email: normalised) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by provider and provider uid.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec get_user_by_provider(String.t(), String.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_provider(provider, provider_uid, repo \\ Repo)
      when is_binary(provider) and is_binary(provider_uid) do
    case repo.get_by(UserSchema, provider: provider, provider_uid: provider_uid) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by GitHub user ID.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.

  When called without a repo, converts an integer ID to string for lookup.
  Accepts an optional `repo` argument for use within transactions (expects a string ID).
  """
  @spec get_user_by_github_id(integer() | String.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_github_id(github_user_id, repo \\ Repo)

  def get_user_by_github_id(github_user_id, repo) when is_integer(github_user_id) do
    get_user_by_github_id(Integer.to_string(github_user_id), repo)
  end

  def get_user_by_github_id(github_user_id, repo) when is_binary(github_user_id) do
    case repo.get_by(UserSchema, github_user_id: github_user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by Google user ID.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec get_user_by_google_id(String.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_google_id(google_user_id, repo \\ Repo) when is_binary(google_user_id) do
    case repo.get_by(UserSchema, google_user_id: google_user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a user.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec create_user(map(), module()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_user(attrs \\ %{}, repo \\ Repo) do
    %UserSchema{}
    |> UserSchema.registration_changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Creates a user from social auth.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec create_social_user(map(), module()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_social_user(attrs \\ %{}, repo \\ Repo) do
    %UserSchema{}
    |> UserSchema.social_registration_changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Updates the user's interface language preference. Pass `nil` (or an empty
  string) to clear it and fall back to browser/session locale detection.
  """
  @spec update_user_locale(UserSchema.t(), String.t() | nil, module()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user_locale(%UserSchema{} = user, locale, repo \\ Repo) do
    user
    |> UserSchema.locale_changeset(%{locale: locale})
    |> repo.update()
  end

  @doc """
  Deletes the given user row.

  Bare single-table delete. Callers needing the anonymise-then-delete
  transaction (required for tax-record retention, see
  `Tymeslot.Auth.AccountDeletion`) must use `Tymeslot.Auth.delete_account/1`
  rather than calling this directly.
  """
  @spec delete_user_row(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def delete_user_row(%UserSchema{} = user) do
    Repo.delete(user)
  end

  @doc """
  Updates a user's password with confirmation. Like every password change, it
  revokes any outstanding reset or email change token.
  """
  @spec update_user_password(UserSchema.t(), String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user_password(%UserSchema{} = user, new_password, new_password_confirmation) do
    user
    |> UserSchema.password_reset_changeset(%{
      password: new_password,
      password_confirmation: new_password_confirmation
    })
    |> Repo.update()
    |> UserSchema.drop_plaintext_password()
  end

  @doc """
  Stamps `last_active_at` with the current UTC time for the given user id.

  Called when a session is created (i.e. on login). Because sessions are
  short-lived and non-renewing, login time is a sufficient proxy for activity
  when measuring account inactivity. Uses `update_all` so it neither loads the
  user nor bumps `updated_at`.
  """
  @spec touch_last_active_at(integer()) :: :ok
  def touch_last_active_at(user_id) do
    query = from(u in UserSchema, where: u.id == ^user_id)
    Repo.update_all(query, set: [last_active_at: DateTime.utc_now(:second)])
    :ok
  end

  @doc """
  Checks whether an email is free to become someone's pending email: no user
  holds it as their address or as their own pending change.

  This is a fast pre-check for a friendly error, not the guard. Two concurrent
  requests can both pass it; the unique index on `pending_email` (and on
  `lower(email)` at confirmation) is what settles the race.
  """
  @spec check_email_availability(String.t()) :: {:ok, :available} | {:error, :taken}
  def check_email_availability(email) when is_binary(email) do
    email = String.downcase(email)

    taken? =
      UserSchema
      |> where([u], u.email == ^email or u.pending_email == ^email)
      |> Repo.exists?()

    if taken?, do: {:error, :taken}, else: {:ok, :available}
  end
end
