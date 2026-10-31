defmodule Tymeslot.Security.TrustedProxies do
  @moduledoc """
  The operator-declared proxy ranges (`TRUSTED_PROXIES`): public addresses,
  such as a CDN's edges, that are proxy hops rather than visitors.

  `config/runtime.exs` stores the validated entries under `:trusted_proxies`.
  The endpoint hands the same strings to `RemoteIp` as `proxies:` for the conn
  path, and `TymeslotWeb.Helpers.ClientIP` matches against them here for the
  LiveView socket path, so both paths read one list.
  """

  import Bitwise, only: [bsr: 2]

  @typedoc "A parsed range: its address and prefix length."
  @type block :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  Parses the `TRUSTED_PROXIES` environment variable into the list
  `config/runtime.exs` stores under `:trusted_proxies`.

  A comma-separated list of addresses or CIDR ranges, IPv4 or IPv6
  (`173.245.48.0/20, 2400:cb00::/32, 198.51.100.7`). Whitespace around an
  entry and empty entries are ignored, so unset or blank yields `[]`.

  Raises `ArgumentError` on an entry that is not an address or CIDR range.
  `RemoteIp` parses its `proxies:` list on every request and would raise there
  instead, failing every request rather than the boot.
  """
  @spec from_env(String.t() | nil) :: [String.t()]
  def from_env(nil), do: []

  def from_env(value) when is_binary(value) do
    entries =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.each(entries, &parse!/1)
    entries
  end

  @doc """
  Parses one entry into a `t:block/0`, raising `ArgumentError` if it is not an
  address or CIDR range.

  No looser than `RemoteIp`'s own parser, so any list this accepts `RemoteIp`
  accepts too: a strict address (all four IPv4 octets), then an optional
  decimal prefix within the address family's width. A bare address is a range
  of one.
  """
  @spec parse!(String.t()) :: block()
  def parse!(entry) when is_binary(entry) do
    {address, prefix} =
      case String.split(entry, "/", parts: 2) do
        [address, prefix] -> {address, prefix}
        [address] -> {address, nil}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {:ok, bits} <- parse_prefix(prefix, width(ip)) do
      {ip, bits}
    else
      _invalid ->
        raise ArgumentError,
              "TRUSTED_PROXIES entry #{inspect(entry)} is not an IP address or CIDR range"
    end
  end

  @doc """
  Whether `address` falls inside `block`.

  An IPv4 address never matches an IPv6 range or the reverse, and an
  IPv4-mapped IPv6 address is not unmapped first: `RemoteIp` matches a
  forwarded address the same way, and the two paths must agree. A caller that
  needs a mapped socket peer matched as IPv4 unmaps it before calling.
  """
  @spec contains?(block(), :inet.ip_address()) :: boolean()
  def contains?({network, bits}, address) when tuple_size(network) == tuple_size(address) do
    shift = width(address) - bits
    bsr(to_integer(network), shift) == bsr(to_integer(address), shift)
  end

  def contains?(_block, _address), do: false

  defp parse_prefix(nil, width), do: {:ok, width}

  defp parse_prefix(prefix, width) do
    case Integer.parse(prefix) do
      {bits, ""} when bits in 0..width//1 -> {:ok, bits}
      _invalid -> :error
    end
  end

  defp width(address) when tuple_size(address) == 4, do: 32
  defp width(address) when tuple_size(address) == 8, do: 128

  defp to_integer({a, b, c, d}) do
    <<value::32>> = <<a::8, b::8, c::8, d::8>>
    value
  end

  defp to_integer({a, b, c, d, e, f, g, h}) do
    <<value::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    value
  end
end
