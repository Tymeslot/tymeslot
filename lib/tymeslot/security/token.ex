defmodule Tymeslot.Security.Token do
  @moduledoc """
  Generation and hashing of the random tokens used for sessions and account links.
  """

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
