defmodule Tymeslot.Security.Token do
  @behaviour Tymeslot.Infrastructure.TokenBehaviour
  @moduledoc """
  Utilities for generating secure tokens for authentication (session, verification, etc).
  """

  require Logger
  alias Plug.Crypto

  @session_token_validity_hours 24

  @doc """
  Generates a strong random session token and expiry datetime.
  Returns {token, expiry}.
  """
  @spec generate_session_token(integer()) :: {String.t(), DateTime.t()}
  def generate_session_token(_user_id) do
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
  def generate_email_verification_token(_user_id) do
    token = generate_strong_token()
    # 2 hours expiry
    expiry = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
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
  Verifies a token against an expiry datetime.
  Returns {:ok, token} if valid, {:error, :token_expired} if expired.
  """
  @spec verify_token(String.t(), DateTime.t()) :: {:ok, String.t()} | {:error, :token_expired}
  def verify_token(token, expiry_datetime) do
    case DateTime.compare(DateTime.utc_now(), expiry_datetime) do
      :lt -> {:ok, token}
      _ -> {:error, :token_expired}
    end
  end

  @doc """
  Securely verifies a token against expected value and expiry with timing attack resistance.
  Returns {:ok, token} if valid, {:error, :token_invalid} if invalid or expired.
  """
  @spec verify_token_secure(String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, :token_invalid}
  def verify_token_secure(provided_token, expected_token, expiry_datetime) do
    # Always perform both checks regardless of individual results
    time_valid = DateTime.compare(DateTime.utc_now(), expiry_datetime) == :lt
    token_valid = secure_compare_tokens(provided_token, expected_token)

    # Use constant-time AND operation
    if time_valid and token_valid do
      {:ok, provided_token}
    else
      # Always sleep a small random amount to prevent timing analysis
      :timer.sleep(:rand.uniform(50))
      {:error, :token_invalid}
    end
  end

  @doc """
  Securely compares two tokens using constant-time comparison to prevent timing attacks.
  """
  @spec secure_compare_tokens(String.t(), String.t()) :: boolean()
  def secure_compare_tokens(token1, token2) when is_binary(token1) and is_binary(token2) do
    # Use Phoenix's built-in secure comparison
    Crypto.secure_compare(token1, token2)
  end

  def secure_compare_tokens(_, _), do: false
end
