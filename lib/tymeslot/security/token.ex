defmodule Tymeslot.Security.Token do
  @moduledoc """
  Generation and hashing of the random tokens used for sessions and account links.
  """

  alias Ecto.Changeset

  @doc """
  Generates an unguessable, URL-safe token: `bytes` random bytes (32 by
  default), base64url without padding. The one place the app mints random
  tokens for sessions, account links, public resource links, OAuth state and
  CSP nonces.
  """
  @spec generate(pos_integer()) :: String.t()
  def generate(bytes \\ 32) when is_integer(bytes) and bytes > 0 do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
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
  Keeps `hash_field` the hash of the token changing in `field`: set when the
  token is, cleared when it is cleared, and left alone when it does not
  change. The column a token is looked up by is always the hash, never the
  token itself.
  """
  @spec put_hash(Changeset.t(), atom(), atom()) :: Changeset.t()
  def put_hash(%Changeset{} = changeset, field, hash_field) do
    case Changeset.fetch_change(changeset, field) do
      {:ok, nil} -> Changeset.put_change(changeset, hash_field, nil)
      {:ok, token} -> Changeset.put_change(changeset, hash_field, hash_token(token))
      :error -> changeset
    end
  end
end
