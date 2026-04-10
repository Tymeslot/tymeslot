defmodule Tymeslot.Security.IPNormaliser do
  @moduledoc """
  Utility functions for normalising and handling IP addresses before storage.
  """

  @doc """
  Normalises an IP address value into a consistently formatted string for database storage.

  Handles binaries, charlists (e.g. from `:inet.ntoa/1`), tuples, `nil`, and `false`.
  Returns `nil` for values that cannot be meaningfully converted.
  """
  @spec normalize_for_storage(term()) :: String.t() | nil
  def normalize_for_storage(nil), do: nil
  def normalize_for_storage(false), do: nil

  def normalize_for_storage(ip) when is_binary(ip) do
    String.trim(ip)
  end

  # Charlists (e.g. inet_ntoa) are common; only accept printable ones.
  def normalize_for_storage(ip) when is_list(ip) do
    if List.ascii_printable?(ip) do
      ip |> to_string() |> String.trim()
    else
      nil
    end
  end

  def normalize_for_storage(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  def normalize_for_storage(_value), do: nil

  @doc """
  Conditionally sets the signup IP in a changes map, preserving the first captured value.

  Verification re-sends should not overwrite an existing signup_ip — the field name
  implies it records the IP from the original sign-up.
  """
  @spec maybe_set_signup_ip(map(), String.t() | nil, String.t()) :: map()
  def maybe_set_signup_ip(changes, existing_signup_ip, normalized_ip) do
    if existing_signup_ip in [nil, "", "unknown"] do
      Map.put(changes, :signup_ip, normalized_ip)
    else
      changes
    end
  end
end
