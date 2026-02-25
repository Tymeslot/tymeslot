defmodule Tymeslot.Utils.UriUtils do
  @moduledoc """
  Utility functions for URI comparison and decoding.
  """

  @doc """
  Decodes a percent-encoded URI string. Returns the original string unchanged
  if the input contains malformed percent-sequences (e.g. `%GG`), rather than
  raising.
  """
  @spec safe_decode(String.t()) :: String.t()
  def safe_decode(str) do
    URI.decode(str)
  rescue
    ArgumentError -> str
  end

  @doc """
  Compares two URI strings for equality, treating percent-encoded and decoded
  forms as equivalent (per RFC 3986). Returns `false` if either argument is nil.
  """
  @spec uri_safe_match?(String.t() | nil, String.t() | nil) :: boolean()
  def uri_safe_match?(a, b) when is_binary(a) and is_binary(b) do
    a == b || safe_decode(a) == safe_decode(b)
  end

  def uri_safe_match?(_a, _b), do: false
end
