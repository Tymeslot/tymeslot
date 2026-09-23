defmodule Tymeslot.Auth.AccountTokens do
  @moduledoc """
  Lifecycle of the single-use tokens mailed to account holders: password
  reset, email verification and email change.

  Each purpose declares its lifetime once, here. The raw token only ever
  exists in the emailed link; the database stores its hash, stamped with the
  moment it was issued, and a token is valid while that stamp is younger than
  the purpose's lifetime.

    * `issue/3` mints a token and persists its hash
    * `fetch/3` resolves a raw token to its user, rejecting unknown, consumed
      and expired tokens
    * `consume/3` spends it
  """

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.Token

  @type purpose :: :reset | :verification | :email_change

  @ttl_seconds %{
    reset: 2 * 3600,
    verification: 24 * 3600,
    email_change: 24 * 3600
  }

  @issued_at_field %{
    reset: :reset_sent_at,
    verification: :verification_sent_at,
    email_change: :email_change_sent_at
  }

  @doc """
  How long a token of `purpose` stays valid after it is issued, in seconds.
  """
  @spec ttl_seconds(purpose()) :: pos_integer()
  def ttl_seconds(purpose), do: Map.fetch!(@ttl_seconds, purpose)

  @doc """
  Mints a token for `user` and persists its hash, replacing any earlier token
  of the same purpose.

  `attrs` carries what a purpose needs besides the token: `:ip_address` for
  verification (recorded as the signup IP), `:new_email` for an email change.

  Returns the updated user and the raw token to put in the emailed link.
  """
  @spec issue(purpose(), UserSchema.t(), map()) ::
          {:ok, UserSchema.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def issue(purpose, %UserSchema{} = user, attrs \\ %{}) do
    token = Token.generate_token()

    case persist(purpose, user, token, attrs) do
      {:ok, updated_user} -> {:ok, updated_user, token}
      {:error, _changeset} = error -> error
    end
  end

  defp persist(:reset, user, token, _attrs),
    do: queries().set_reset_token(user, token)

  defp persist(:verification, user, token, attrs),
    do: queries().set_verification_token(user, token, Map.get(attrs, :ip_address))

  defp persist(:email_change, user, token, %{new_email: new_email}),
    do: queries().request_email_change(user, new_email, token)

  @doc """
  Resolves a raw token to the user holding it.

  Pass `lock: true` inside a transaction to lock the user's row, so two
  concurrent consumers of the same token cannot both succeed.

  An expired token still names its user, so the caller can attribute the
  failure in the audit log without ever logging the token.
  """
  @spec fetch(purpose(), String.t(), keyword()) ::
          {:ok, UserSchema.t()}
          | {:error, :invalid_token}
          | {:error, :token_expired, UserSchema.t()}
  def fetch(purpose, token, opts \\ []) when is_binary(token) do
    case queries().get_user_by_token(purpose, token, opts) do
      {:error, :not_found} ->
        {:error, :invalid_token}

      {:ok, user} ->
        if expired?(purpose, user), do: {:error, :token_expired, user}, else: {:ok, user}
    end
  end

  @doc """
  Whether `user`'s token of `purpose` has outlived its lifetime. A token with
  no issue stamp counts as expired.
  """
  @spec expired?(purpose(), UserSchema.t()) :: boolean()
  def expired?(purpose, %UserSchema{} = user) do
    case Map.fetch!(user, Map.fetch!(@issued_at_field, purpose)) do
      nil ->
        true

      %DateTime{} = issued_at ->
        expires_at = DateTime.add(issued_at, ttl_seconds(purpose), :second)
        DateTime.compare(Clock.utc_now(), expires_at) != :lt
    end
  end

  @doc """
  Spends the token `user` holds for `purpose`.

    * `:reset` sets the password from `attrs` (`:password`,
      `:password_confirmation`)
    * `:verification` marks the account verified
    * `:email_change` moves the pending email into place

  A reset and an email change both change the account's credentials, so both
  also revoke every other outstanding credential token.
  """
  @spec consume(purpose(), UserSchema.t(), map()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t()}
  def consume(purpose, user, attrs \\ %{})

  def consume(:reset, %UserSchema{} = user, attrs),
    do: queries().consume_reset_token(user, attrs)

  def consume(:verification, %UserSchema{} = user, _attrs),
    do: queries().consume_verification_token(user)

  def consume(:email_change, %UserSchema{} = user, _attrs),
    do: queries().confirm_email_change(user)

  defp queries, do: Config.user_token_queries_module()
end
