defmodule Tymeslot.Security.Token do
  @behaviour Tymeslot.Infrastructure.TokenBehaviour
  @moduledoc """
  Utilities for generating secure tokens for authentication (session, verification, etc).
  """

  alias Tymeslot.Clock

  @session_token_validity_hours 24

  @doc """
  Generates a strong random session token and expiry datetime.
  Returns {token, expiry}.
  """
  @spec generate_session_token(integer()) :: {String.t(), DateTime.t()}
  def generate_session_token(_unused_user_id) do
    token = generate_strong_token()
    expiry = DateTime.add(Clock.utc_now(), @session_token_validity_hours * 3600, :second)
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
end
