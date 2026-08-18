defmodule Tymeslot.Utils.UnguessableToken do
  @moduledoc """
  Unguessable, URL-safe tokens for publicly addressable resources
  (poll links, participant identities).
  """

  @token_bytes 24

  @spec generate() :: String.t()
  def generate do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
