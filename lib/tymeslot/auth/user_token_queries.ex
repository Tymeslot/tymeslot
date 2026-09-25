defmodule Tymeslot.Auth.UserTokenQueries do
  @moduledoc """
  Query interface for user token lifecycle operations — verification tokens,
  password reset tokens, and email change tokens.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Auth.{AccountTokens, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.IPNormaliser
  alias Tymeslot.Security.Token

  @doc """
  Sets verification token for a user.
  """
  @spec set_verification_token(UserSchema.t(), String.t(), String.t() | nil) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_verification_token(%UserSchema{} = user, token, ip_address \\ nil) do
    normalized_ip = IPNormaliser.normalize_for_storage(ip_address)
    token_hash = Token.hash_token(token)

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
  Sets password reset token for a user.
  """
  @spec set_reset_token(UserSchema.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  # Issuing a new link clears any previous used_at marker.
  def set_reset_token(%UserSchema{} = user, token) when is_binary(token) do
    token_hash = Token.hash_token(token)

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

  @doc """
  Gets the user holding a live token of the given purpose.

  A token is live while its hash is stored and it has not been consumed:
  reset and verification tokens are stamped `*_used_at` when used, and an
  email change token only means something while a `pending_email` waits for
  it. Expiry is not checked here; that is a business rule owned by
  `Tymeslot.Auth.AccountTokens`.

  Pass `lock: true` to take a row lock (`FOR UPDATE`) so concurrent consumers
  of the same token serialise; the call must then run inside a transaction.
  """
  @spec get_user_by_token(AccountTokens.purpose(), String.t(), keyword()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def get_user_by_token(purpose, token, opts \\ []) when is_binary(token) do
    token_hash = Token.hash_token(token)

    query =
      purpose
      |> live_token_query(token_hash)
      |> maybe_lock(Keyword.get(opts, :lock, false))

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp live_token_query(:reset, hash) do
    where(UserSchema, [u], u.reset_token_hash == ^hash and is_nil(u.reset_token_used_at))
  end

  defp live_token_query(:verification, hash) do
    where(
      UserSchema,
      [u],
      u.verification_token == ^hash and is_nil(u.verification_token_used_at)
    )
  end

  defp live_token_query(:email_change, hash) do
    where(UserSchema, [u], u.email_change_token_hash == ^hash and not is_nil(u.pending_email))
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  @doc """
  Consumes a password reset token: sets the new password, marks the token used
  and, through `UserSchema.password_reset_changeset/2`, revokes every other
  outstanding credential token.
  """
  @spec consume_reset_token(UserSchema.t(), map()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def consume_reset_token(%UserSchema{} = user, attrs) do
    now = DateTime.utc_now(:second)

    user
    |> UserSchema.password_reset_changeset(attrs)
    |> Changeset.put_change(:reset_token_used_at, now)
    |> verify_through_reset(user, now)
    |> Repo.update()
    |> UserSchema.drop_plaintext_password()
  end

  # The reset link was delivered to the account's address, so following it
  # proves the mailbox just as the verification link would. Verifying here is
  # what lets an address's owner reclaim an account someone else signed up
  # with it: the reset replaces the stranger's password and makes it theirs.
  defp verify_through_reset(changeset, %UserSchema{verified_at: nil}, now) do
    Changeset.change(changeset,
      verified_at: now,
      verification_token: nil,
      verification_token_used_at: now
    )
  end

  defp verify_through_reset(changeset, _verified_user, _now), do: changeset

  @doc """
  Consumes a verification token: marks the user verified and the token used.
  Intentionally keeps `signup_ip` for the audit trail and fraud detection.
  """
  @spec consume_verification_token(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def consume_verification_token(%UserSchema{} = user) do
    now = DateTime.utc_now(:second)

    user
    |> Changeset.change(
      verified_at: now,
      verification_token_used_at: now,
      verification_token: nil
    )
    |> Repo.update()
  end

  @doc """
  Initiates an email change request for a user.
  Returns {:ok, user} on success, {:error, changeset} on failure.
  """
  @spec request_email_change(UserSchema.t(), String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def request_email_change(%UserSchema{} = user, new_email, token_raw) do
    token_hash = Token.hash_token(token_raw)

    user
    |> UserSchema.email_change_request_changeset(%{
      pending_email: new_email,
      email_change_token_hash: token_hash
    })
    |> Repo.update()
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
