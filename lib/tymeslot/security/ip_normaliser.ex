defmodule Tymeslot.Security.IPNormaliser do
  @moduledoc """
  Utility functions for normalising IP addresses before storage, and for
  truncating them before they are logged.
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
  Truncates a client IP address to the network it belongs to, for a log line.

  IPv4 keeps its /24 (`"203.0.113.7"` becomes `"203.0.113.0/24"`) and IPv6
  its /48 (`"2001:db8:1:2::9"` becomes `"2001:db8:1::/48"`), which is enough
  to tell one network's traffic from another's but no longer names a
  visitor. An IPv4-mapped IPv6 address is truncated as the IPv4 address it
  carries. A comma-separated list (an `X-Forwarded-For` value) has each entry
  truncated.

  Accepts binaries, printable charlists and `:inet` address tuples. Returns
  `:error` for anything that is not an address, so the caller can decide
  what to put in its place rather than log the value as it came.

  Only for logs: rate limiting and account lockout key on the full address.
  """
  @spec truncate_for_log(term()) :: {:ok, String.t()} | :error
  def truncate_for_log(ip) when is_binary(ip) do
    truncated =
      ip
      |> String.split(",")
      |> Enum.reduce_while([], fn entry, acc ->
        case parse(String.trim(entry)) do
          {:ok, address} -> {:cont, [truncate(address) | acc]}
          :error -> {:halt, :error}
        end
      end)

    case truncated do
      :error -> :error
      networks -> {:ok, networks |> Enum.reverse() |> Enum.join(", ")}
    end
  end

  def truncate_for_log(ip) when is_list(ip) do
    if List.ascii_printable?(ip), do: ip |> to_string() |> truncate_for_log(), else: :error
  end

  def truncate_for_log(ip) when tuple_size(ip) in [4, 8] do
    if :inet.is_ip_address(ip), do: {:ok, truncate(ip)}, else: :error
  end

  def truncate_for_log(_value), do: :error

  defp parse(string) do
    case :inet.parse_strict_address(String.to_charlist(string)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp truncate({a, b, c, _d}), do: "#{:inet.ntoa({a, b, c, 0})}/24"

  defp truncate({0, 0, 0, 0, 0, 0xFFFF, _high, _low} = mapped),
    do: mapped |> :inet.ipv4_mapped_ipv6_address() |> truncate()

  defp truncate({a, b, c, _d, _e, _f, _g, _h}),
    do: "#{:inet.ntoa({a, b, c, 0, 0, 0, 0, 0})}/48"

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
