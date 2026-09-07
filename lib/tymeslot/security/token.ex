defmodule Tymeslot.Security.Token do
  @behaviour Tymeslot.Infrastructure.TokenBehaviour
  @moduledoc """
  Utilities for generating secure tokens for authentication (session, verification, etc).
  """

  @session_token_validity_hours 24

  @doc """
  Generates a strong random session token and expiry datetime.
  Returns {token, expiry}.
  """
  @spec generate_session_token(integer()) :: {String.t(), DateTime.t()}
  def generate_session_token(_unused_user_id) do
    token = generate_strong_token()
    expiry = DateTime.add(DateTime.utc_now(), @session_token_validity_hours * 3600, :second)
    {token, expiry}
  end

  @doc """
  Generates a strong random session token.
  Returns just the token string.
  """
  @spec generate_session_token() :: String.t()
  def generate_session_token do
    generate_strong_token()
  end

  @doc """
  Generates a generic secure token.
  """
  @spec generate_token() :: String.t()
  def generate_token do
    generate_strong_token()
  end

  @doc """
  Generates an email verification token for a user.
  Returns {token, expiry, purpose}.
  """
  @spec generate_email_verification_token(integer()) :: {String.t(), DateTime.t(), String.t()}
  def generate_email_verification_token(_unused_user_id) do
    token = generate_strong_token()
    # 24 hours expiry
    expiry = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)
    purpose = "email_verification"
    {token, expiry, purpose}
  end

  @doc """
  Generates a password reset token and expiry datetime.
  Returns {token, expiry}.
  """
  @spec generate_password_reset_token() :: {String.t(), DateTime.t()}
  def generate_password_reset_token do
    token = generate_strong_token()
    # 2 hours expiry
    expiry = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
    {token, expiry}
  end

  defp generate_strong_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc """
  Hashes a raw token for storage and comparison (SHA-256, lowercase hex).

  Single source of truth for token hashing: both persistence
  (`Tymeslot.Auth.UserTokenQueries`) and the email worker's staleness guard
  rely on this producing identical output, so the hash must only ever be
  computed here.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) do
    Base.encode16(:crypto.hash(:sha256, token), case: :lower)
  end

  @doc """
  Verifies a token against an expiry datetime.
  Returns {:ok, token} if valid, {:error, :token_expired} if expired.
  """
  @spec verify_token(String.t(), DateTime.t()) :: {:ok, String.t()} | {:error, :token_expired}
  def verify_token(token, expiry_datetime) do
    case DateTime.compare(DateTime.utc_now(), expiry_datetime) do
      :lt -> {:ok, token}
      _expired -> {:error, :token_expired}
    end
  end
end
