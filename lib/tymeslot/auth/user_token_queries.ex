defmodule Tymeslot.Auth.UserTokenQueries do
  @moduledoc """
  Query interface for user token lifecycle operations — verification tokens,
  password reset tokens, and email change tokens.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.IPNormaliser

  @doc """
  Sets verification token for a user.
  """
  @spec set_verification_token(UserSchema.t(), String.t(), String.t() | nil) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_verification_token(%UserSchema{} = user, token, ip_address \\ nil) do
    normalized_ip = IPNormaliser.normalize_for_storage(ip_address)
    token_hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

    changes = %{
      verification_token: token_hash,
      verification_sent_at: DateTime.utc_now(:second)
    }

    changes =
      if normalized_ip in [nil, "", "unknown"],
        do: changes,
        else: IPNormaliser.maybe_set_signup_ip(changes, user.signup_ip, normalized_ip)

    user
    |> Changeset.change(changes)
    |> Repo.update()
  end

  @doc """
  Gets a user by verification token, only if not already used.
  Returns {:ok, user} if found, {:error, :not_found} otherwise.
  """
  @spec get_user_by_verification_token(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_verification_token(token) when is_binary(token) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

    case UserSchema
         |> where(
           [u],
           u.verification_token == ^token_hash and is_nil(u.verification_token_used_at)
         )
         |> Repo.one() do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

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
        reset_sent_at: DateTime.utc_now(:second),
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
end
