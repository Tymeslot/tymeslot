defmodule Tymeslot.EmailSending.Destination do
  @moduledoc """
  Resolves user SMTP destinations to approved addresses for a single connection.

  The caller connects to the returned address, never resolves the original
  hostname again. TLS must still verify the original hostname. Unlike the
  calendar integration policy, this boundary has no private-network opt-out.
  """

  alias Tymeslot.Security.{DnsResolution, PrivateIPv4, PrivateIPv6, UrlValidation}

  @type endpoint :: %{address: :inet.ip_address(), port: 465 | 587}
  @type error :: :feature_disabled | :invalid_settings | :invalid_destination | :dns_failed

  @callback resolve(String.t(), pos_integer()) :: {:ok, endpoint()} | {:error, error()}

  @doc "Resolves a public SMTP hostname and returns the exact address to connect to."
  @spec resolve(term(), term()) :: {:ok, endpoint()} | {:error, error()}
  def resolve(host, port) do
    cond do
      Application.get_env(:tymeslot, :user_smtp_enabled, false) != true ->
        {:error, :feature_disabled}

      not valid_host?(host) or port not in [465, 587] ->
        {:error, :invalid_settings}

      true ->
        resolve_public(host, port)
    end
  end

  @doc "Validates a DNS hostname without accepting URLs, IP literals, or credentials."
  @spec valid_host?(term()) :: boolean()
  def valid_host?(host) when is_binary(host) and byte_size(host) in 1..253 do
    String.valid?(host) and not UrlValidation.internal_name?(host) and
      Regex.match?(
        ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i,
        host
      )
  end

  def valid_host?(_host), do: false

  defp resolve_public(host, port) do
    resolver = Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)

    case resolver.resolve_public("https://" <> host, []) do
      {:ok, [address | _rest] = addresses} ->
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, %{address: address, port: port}},
          else: {:error, :invalid_destination}

      {:ok, []} ->
        {:error, :dns_failed}

      {:error, _reason} ->
        {:error, :dns_failed}
    end
  end

  # The common policy covers private/embedded addresses. SMTP additionally
  # refuses documentation and benchmarking networks, which are not relays.
  defp public_address?({a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not PrivateIPv4.private?(address) and
      not reserved_ipv4?(address)
  end

  defp public_address?({a, b, c, d, e, f, g, h} = address)
       when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
              e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    a in 0x2000..0x3FFF and not PrivateIPv6.private?(address) and
      not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and
      a not in [0x2002, 0x3FFF]
  end

  defp public_address?(_address), do: false

  defp reserved_ipv4?({192, 0, 2, _d}), do: true
  defp reserved_ipv4?({192, 88, 99, _d}), do: true
  defp reserved_ipv4?({198, b, _c, _d}) when b in [18, 19], do: true
  defp reserved_ipv4?({198, 51, 100, _d}), do: true
  defp reserved_ipv4?({203, 0, 113, _d}), do: true
  defp reserved_ipv4?(_address), do: false
end
