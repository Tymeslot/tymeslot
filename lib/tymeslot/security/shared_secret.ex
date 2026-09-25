defmodule Tymeslot.Security.SharedSecret do
  @moduledoc """
  Compares a secret a caller presents against the one we hold.

  Webhook endpoints authenticate their provider by a value the provider
  echoes back (a header or a field in the payload). An unset or empty secret
  on our side must never turn that check into "anyone who sends an empty
  value is trusted", so both sides have to be non-empty strings before the
  timing-safe comparison runs.
  """

  alias Plug.Crypto

  @doc """
  Returns `true` only when both values are non-empty strings and equal.

  The comparison is timing-safe. `nil`, an empty string or a non-string on
  either side never matches.
  """
  @spec matches?(term(), term()) :: boolean()
  def matches?(received, expected)
      when is_binary(received) and is_binary(expected) and byte_size(received) > 0 and
             byte_size(expected) > 0 do
    Crypto.secure_compare(received, expected)
  end

  def matches?(_received, _expected), do: false
end
