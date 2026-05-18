defmodule Tymeslot.Auth.UserQueries do
  @moduledoc """
  Query interface for user-related database operations.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Repo
  alias Tymeslot.Security.Password

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
  Gets a user by email and password.
  Returns {:ok, user} if found and password matches, {:error, :invalid_credentials} otherwise.
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, :invalid_credentials}
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    case Repo.get_by(UserSchema, email: email) do
      nil ->
        {:error, :invalid_credentials}

      user ->
        if Password.verify_password(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Lists all users in the system, ordered by id ascending.
  Profiles are preloaded so callers (e.g. the admin users tab) can show
  booking slug and display name without N+1 queries.
  Returns a list of user records (can be empty).
  """
  @spec list_all_users() :: [UserSchema.t()]
  def list_all_users do
    Repo.all(from(u in UserSchema, order_by: u.id, preload: [:profile]))
  end

  @doc """
  Lists all active user IDs in the system.
  More efficient than loading full user records when only IDs are needed.
  Returns a list of user IDs.
  """
  @spec list_all_user_ids() :: [integer()]
  def list_all_user_ids do
    UserSchema
    |> select([u], u.id)
    |> Repo.all()
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
  Updates a user.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec update_user(UserSchema.t(), map(), module()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user(%UserSchema{} = user, attrs, repo \\ Repo) do
    user
    |> UserSchema.changeset(attrs)
    |> repo.update()
  end

  @doc """
  Returns `true` if `user` is the only row in the `users` table.

  Accepts an optional `repo` argument for use within transactions — the call
  site is expected to run this inside the same transaction as the insert it
  is gating, to keep the "first user becomes admin" bootstrap race-free for a
  single-instance install.
  """
  @spec only_user?(UserSchema.t(), module()) :: boolean()
  def only_user?(%UserSchema{id: id}, repo \\ Repo) do
    not repo.exists?(from(u in UserSchema, where: u.id != ^id, select: 1, limit: 1))
  end

  @doc """
  Returns `true` if at least one row in `users` has `is_admin = true`.
  """
  @spec any_admin?(module()) :: boolean()
  def any_admin?(repo \\ Repo) do
    repo.exists?(from(u in UserSchema, where: u.is_admin, select: 1, limit: 1))
  end

  @doc """
  Returns `true` if at least one admin has a `password_hash` set — i.e. is
  capable of signing in via email + password. Used by the lockout-protection
  check in `Tymeslot.AppSettings` to refuse disabling password authentication
  while any admin still depends on it.
  """
  @spec any_admin_uses_password_auth?(module()) :: boolean()
  def any_admin_uses_password_auth?(repo \\ Repo) do
    repo.exists?(
      from(u in UserSchema,
        where: u.is_admin and not is_nil(u.password_hash),
        select: 1,
        limit: 1
      )
    )
  end

  @doc """
  Returns `true` if the `users` table has at least one row.
  """
  @spec any_user?(module()) :: boolean()
  def any_user?(repo \\ Repo) do
    repo.exists?(from(u in UserSchema, select: 1, limit: 1))
  end

  @doc """
  Sets `is_admin` on a user. Internal-only — callers must have already
  verified that the actor is authorised to make this change.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec set_admin(UserSchema.t(), boolean(), module()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_admin(%UserSchema{} = user, is_admin, repo \\ Repo) when is_boolean(is_admin) do
    user
    |> UserSchema.admin_changeset(is_admin)
    |> repo.update()
  end

  @doc """
  Returns every admin user, ordered by id.
  """
  @spec list_admins(module()) :: [UserSchema.t()]
  def list_admins(repo \\ Repo) do
    repo.all(from(u in UserSchema, where: u.is_admin, order_by: u.id))
  end

  @doc """
  Acquires a `FOR UPDATE` row lock on every admin user and returns them.

  Must be called inside a transaction. Used by `AdminRoles` to prevent
  concurrent demotions from racing past the last-admin invariant.
  """
  @spec lock_admins() :: [UserSchema.t()]
  def lock_admins do
    Repo.all(from(u in UserSchema, where: u.is_admin == true, lock: "FOR UPDATE"))
  end

  @doc """
  Counts users in the table.
  """
  @spec count_users(module()) :: non_neg_integer()
  def count_users(repo \\ Repo) do
    repo.aggregate(UserSchema, :count, :id)
  end

  @doc """
  Counts admin users.
  """
  @spec count_admins(module()) :: non_neg_integer()
  def count_admins(repo \\ Repo) do
    repo.aggregate(from(u in UserSchema, where: u.is_admin), :count, :id)
  end

  @doc """
  Updates a user changeset using a specific repo (for transactions).
  """
  @spec update_changeset(Changeset.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_changeset(changeset, repo \\ Repo) do
    repo.update(changeset)
  end

  @doc """
  Updates user verification status and marks token as used.
  NOTE: Intentionally keeps signup_ip for audit trail and fraud detection.
  """
  @spec verify_user(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def verify_user(%UserSchema{} = user) do
    user
    |> Changeset.change(
      verified_at: DateTime.utc_now(:second),
      verification_token_used_at: DateTime.utc_now(:second),
      verification_token: nil
      # NOTE: Do NOT clear signup_ip - keep for audit trail
    )
    |> Repo.update()
  end

  @doc """
  Resets user password and marks token as used.
  """
  @spec reset_password(UserSchema.t(), map()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def reset_password(%UserSchema{} = user, attrs) do
    user
    |> UserSchema.password_reset_changeset(attrs)
    |> Changeset.change(
      reset_token_hash: nil,
      reset_sent_at: nil,
      reset_token_used_at: DateTime.utc_now(:second)
    )
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  Runs `Tymeslot.MeetingPayments.anonymise_host/1` before the
  delete so booking-payment and payment-transaction rows are scrubbed and
  marked retained — the FKs on those tables are `:nilify_all`, so the
  rows survive the user delete and must be anonymised in the same
  transaction. Required for tax-record retention under EU and Swiss
  commercial law (GDPR Art. 17(3)(b) carve-out).
  """
  @spec delete_user(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t() | term()}
  def delete_user(%UserSchema{} = user) do
    Repo.transaction(fn ->
      with :ok <- MeetingPayments.anonymise_host(user.id),
           {:ok, deleted} <- Repo.delete(user) do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Gets a user by ID and raises if not found.
  """
  @spec get_user!(integer()) :: UserSchema.t()
  def get_user!(id) do
    Repo.get!(UserSchema, id)
  end

  @doc """
  Updates a user's email.
  """
  @spec update_user_email(UserSchema.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user_email(%UserSchema{} = user, new_email) do
    user
    |> UserSchema.changeset(%{email: new_email})
    |> Repo.update()
  end

  @doc """
  Updates a user's password with confirmation.
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
  end

  @doc """
  Marks a user's onboarding as complete.
  """
  @spec mark_onboarding_complete(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def mark_onboarding_complete(%UserSchema{} = user) do
    user
    |> Changeset.change(%{
      onboarding_completed_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc """
  Sets or clears a user's marketing unsubscribe timestamp.

  Pass a `DateTime` to mark the user as unsubscribed, or `nil` to resubscribe.
  """
  @spec set_marketing_unsubscribed_at(UserSchema.t(), DateTime.t() | nil) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_marketing_unsubscribed_at(%UserSchema{} = user, value) do
    user
    |> Changeset.change(%{marketing_unsubscribed_at: value})
    |> Repo.update()
  end

  @doc """
  Returns the IDs of users currently eligible to receive marketing email — i.e.
  who have a verified email and have not unsubscribed from marketing.
  """
  @spec list_marketing_eligible_user_ids() :: [integer()]
  def list_marketing_eligible_user_ids do
    UserSchema
    |> where([u], not is_nil(u.verified_at) and is_nil(u.marketing_unsubscribed_at))
    |> select([u], u.id)
    |> Repo.all()
  end

  @doc """
  Gets a user by ID with profile preloaded.
  """
  @spec get_user_with_profile!(integer()) :: UserSchema.t()
  def get_user_with_profile!(id) do
    UserSchema
    |> Repo.get!(id)
    |> Repo.preload(:profile)
  end

  @doc """
  Preloads profile for a user.
  """
  @spec preload_profile(UserSchema.t()) :: UserSchema.t()
  def preload_profile(%UserSchema{} = user) do
    Repo.preload(user, :profile)
  end

  @doc """
  Checks whether an email is already registered (case-insensitive).
  Returns `true` if a user with a matching email exists, `false` otherwise.
  """
  @spec email_exists_case_insensitive?(String.t()) :: boolean()
  def email_exists_case_insensitive?(email) when is_binary(email) do
    UserSchema
    |> where([u], fragment("LOWER(?) = LOWER(?)", u.email, ^email))
    |> Repo.exists?()
  end

  @doc """
  Checks if an email is already taken by another user.
  Uses SELECT FOR UPDATE to prevent race conditions.
  Returns {:ok, :available} if email is available, {:error, :taken} if taken.
  """
  @spec check_email_availability(String.t()) :: {:ok, :available} | {:error, :taken}
  def check_email_availability(email) when is_binary(email) do
    email = String.downcase(email)

    # Use a transaction with row-level locking to prevent race conditions
    result =
      Repo.transaction(fn ->
        query =
          UserSchema
          |> where([u], u.email == ^email or u.pending_email == ^email)
          |> lock("FOR UPDATE")

        case Repo.exists?(query) do
          true -> {:error, :taken}
          false -> {:ok, :available}
        end
      end)

    case result do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :taken}
    end
  end
end
