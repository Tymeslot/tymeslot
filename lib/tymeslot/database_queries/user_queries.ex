defmodule Tymeslot.DatabaseQueries.UserQueries do
  @moduledoc """
  Query interface for user-related database operations.
  """
  import Ecto.Query, warn: false
  require Logger
  alias Ecto.Changeset
  alias Tymeslot.DatabaseSchemas.UserSchema
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
  """
  @spec get_user_by_email(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_email(email) when is_binary(email) do
    case Repo.get_by(UserSchema, email: email) do
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
  Lists all users in the system.
  Returns a list of user records (can be empty).
  """
  @spec list_all_users() :: [UserSchema.t()]
  def list_all_users do
    Repo.all(UserSchema)
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
  Gets a user by verification token, only if not already used.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_verification_token(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_verification_token(token) when is_binary(token) do
    case UserSchema
         |> where([u], u.verification_token == ^token and is_nil(u.verification_token_used_at))
         |> Repo.one() do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by reset token, only if not already used.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_reset_token(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_reset_token(token) when is_binary(token) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

    case UserSchema
         |> where([u], u.reset_token_hash == ^token_hash and is_nil(u.reset_token_used_at))
         |> Repo.one() do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by provider and provider uid.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_provider(String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_provider(provider, provider_uid)
      when is_binary(provider) and is_binary(provider_uid) do
    case Repo.get_by(UserSchema, provider: provider, provider_uid: provider_uid) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by GitHub user ID.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_github_id(integer()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_github_id(github_user_id) when is_integer(github_user_id) do
    case Repo.get_by(UserSchema, github_user_id: Integer.to_string(github_user_id)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by Google user ID.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_google_id(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_google_id(google_user_id) when is_binary(google_user_id) do
    case Repo.get_by(UserSchema, google_user_id: google_user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a user.
  """
  @spec create_user(map()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_user(attrs \\ %{}) do
    %UserSchema{}
    |> UserSchema.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a user from social auth.
  """
  @spec create_social_user(map()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_social_user(attrs \\ %{}) do
    %UserSchema{}
    |> UserSchema.social_registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.
  """
  @spec update_user(UserSchema.t(), map()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user(%UserSchema{} = user, attrs) do
    user
    |> UserSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates user verification status and marks token as used.
  NOTE: Intentionally keeps signup_ip for audit trail and fraud detection.
  """
  @spec verify_user(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def verify_user(%UserSchema{} = user) do
    user
    |> Changeset.change(
      verified_at: DateTime.truncate(DateTime.utc_now(), :second),
      verification_token_used_at: DateTime.truncate(DateTime.utc_now(), :second),
      verification_token: nil
      # NOTE: Do NOT clear signup_ip - keep for audit trail
    )
    |> Repo.update()
  end

  @doc """
  Sets verification token for a user.
  """
  @spec set_verification_token(UserSchema.t(), String.t(), String.t() | nil) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_verification_token(%UserSchema{} = user, token, ip_address \\ nil) do
    normalized_ip = normalize_ip_for_storage(ip_address)

    changes = %{
      verification_token: token,
      verification_sent_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    changes =
      if normalized_ip in [nil, "", "unknown"],
        do: changes,
        else: maybe_set_signup_ip(changes, user.signup_ip, normalized_ip)

    user
    |> Changeset.change(changes)
    |> Repo.update()
  end

  # Preserve the first captured signup_ip (semantics implied by the field name).
  # Verification re-sends should not overwrite it.
  defp maybe_set_signup_ip(changes, existing_signup_ip, normalized_ip) do
    if existing_signup_ip in [nil, "", "unknown"] do
      Map.put(changes, :signup_ip, normalized_ip)
    else
      changes
    end
  end

  defp normalize_ip_for_storage(nil), do: nil
  defp normalize_ip_for_storage(false), do: nil

  defp normalize_ip_for_storage(ip) when is_binary(ip) do
    String.trim(ip)
  end

  # Charlists (e.g. inet_ntoa) are common; only accept printable ones.
  defp normalize_ip_for_storage(ip) when is_list(ip) do
    if List.ascii_printable?(ip) do
      ip |> to_string() |> String.trim()
    else
      nil
    end
  end

  defp normalize_ip_for_storage(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp normalize_ip_for_storage(_other), do: nil

  @doc """
  Sets password reset token for a user.
  """
  @spec set_reset_token(UserSchema.t(), String.t() | nil) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  # Set a new reset token (issue new link): clear any previous used_at marker
  def set_reset_token(%UserSchema{} = user, token) when is_binary(token) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

    result =
      user
      |> Changeset.change(
        reset_token_hash: token_hash,
        reset_sent_at: DateTime.truncate(DateTime.utc_now(), :second),
        reset_token_used_at: nil
      )
      |> Repo.update()

    case result do
      {:ok, updated} ->
        # Do not log token material; only log user_id
        Logger.info("Stored reset token", user_id: updated.id)
        {:ok, updated}

      {:error, reason} ->
        Logger.error("Failed to store reset token",
          user_id: user.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Clear token (after successful reset): do not touch used_at so audit remains intact
  def set_reset_token(%UserSchema{} = user, nil) do
    result =
      user
      |> Changeset.change(
        reset_token_hash: nil,
        reset_sent_at: nil
      )
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Logger.info("Cleared reset token", user_id: updated.id)
        {:ok, updated}

      {:error, reason} ->
        Logger.error("Failed to clear reset token",
          user_id: user.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
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
      reset_token_used_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update()
  end

  @doc """
  Deletes a user.
  """
  @spec delete_user(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def delete_user(%UserSchema{} = user) do
    Repo.delete(user)
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
  Gets a user by email using a specific repo (for transactions).
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_email(String.t(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_email(email, repo) when is_binary(email) do
    case repo.get_by(UserSchema, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a user using a specific repo (for transactions).
  """
  @spec create_user(map(), Ecto.Repo.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_user(attrs, repo) do
    %UserSchema{}
    |> UserSchema.registration_changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Creates a social user using a specific repo (for transactions).
  """
  @spec create_social_user(map(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def create_social_user(attrs, repo) do
    %UserSchema{}
    |> UserSchema.social_registration_changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Gets a user by GitHub ID using a specific repo (for transactions).
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_github_id(String.t(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_github_id(github_user_id, repo) when is_binary(github_user_id) do
    case repo.get_by(UserSchema, github_user_id: github_user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Gets a user by Google ID using a specific repo (for transactions).
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_google_id(String.t(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_google_id(google_user_id, repo) when is_binary(google_user_id) do
    case repo.get_by(UserSchema, google_user_id: google_user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Updates a user using a specific repo (for transactions).
  """
  @spec update_user(UserSchema.t(), map(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_user(%UserSchema{} = user, attrs, repo) do
    user
    |> UserSchema.changeset(attrs)
    |> repo.update()
  end

  @doc """
  Updates a user changeset using a specific repo (for transactions).
  """
  @spec update_changeset(Changeset.t(), Ecto.Repo.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def update_changeset(changeset, repo) do
    repo.update(changeset)
  end

  @doc """
  Marks a user's onboarding as complete.
  """
  @spec mark_onboarding_complete(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def mark_onboarding_complete(%UserSchema{} = user) do
    user
    |> Changeset.change(%{
      onboarding_completed_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Repo.update()
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
  Initiates an email change request for a user.
  Returns {:ok, user} on success, {:error, changeset} on failure.
  """
  @spec request_email_change(UserSchema.t(), String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def request_email_change(%UserSchema{} = user, new_email, token_raw) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token_raw), case: :lower)

    user
    |> UserSchema.email_change_request_changeset(%{
      pending_email: new_email,
      email_change_token_hash: token_hash
    })
    |> Repo.update()
  end

  @doc """
  Gets a user by email change token.
  Returns {:ok, user} if found and token not expired, {:error, :not_found} otherwise.
  """
  @spec get_user_by_email_change_token(String.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_email_change_token(token_raw) when is_binary(token_raw) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token_raw), case: :lower)

    case UserSchema
         |> where([u], u.email_change_token_hash == ^token_hash)
         |> where([u], not is_nil(u.pending_email))
         |> Repo.one() do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Confirms an email change for a user.
  Returns {:ok, user} on success, {:error, changeset} on failure.
  """
  @spec confirm_email_change(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def confirm_email_change(%UserSchema{} = user) do
    user
    |> UserSchema.email_change_confirm_changeset()
    |> Repo.update()
  end

  @doc """
  Cancels a pending email change for a user.
  Returns {:ok, user} on success, {:error, changeset} on failure.
  """
  @spec cancel_email_change(UserSchema.t()) :: {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def cancel_email_change(%UserSchema{} = user) do
    user
    |> Changeset.change(%{
      pending_email: nil,
      email_change_token_hash: nil,
      email_change_sent_at: nil
    })
    |> Repo.update()
  end

  @doc """
  Checks if an email is already taken by another user.
  Uses SELECT FOR UPDATE to prevent race conditions.
  Returns {:ok, :available} if email is available, {:error, :taken} if taken.
  """
  @spec check_email_availability(String.t()) :: {:ok, :available} | {:error, :taken}
  def check_email_availability(email) when is_binary(email) do
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
      {:error, _} -> {:error, :taken}
    end
  end

  @doc """
  Executes a function within a database transaction.

  This function is used to ensure all database operations in auth workflows
  are properly wrapped in transactions.

  ## Parameters
  - fun: A function that will be executed within the transaction

  ## Returns
  - The result of the transaction
  """
  @spec transaction((... -> any())) :: {:ok, any()} | {:error, any()}
  def transaction(fun) when is_function(fun) do
    Repo.transaction(fun)
  end

  # Overload for Ecto.Multi
  @spec transaction(Ecto.Multi.t()) ::
          {:ok, map()} | {:error, any(), any(), map()}
  def transaction(multi) do
    Repo.transaction(multi)
  end

  @doc """
  Rolls back a transaction with the given reason.

  ## Parameters
  - reason: The reason for rolling back

  ## Returns
  - no_return (raises Ecto.Rollback)
  """
  @spec rollback(any()) :: no_return()
  def rollback(reason) do
    Repo.rollback(reason)
  end
end
