defmodule Tymeslot.Webhooks.SsrfValidator do
  @moduledoc """
  SSRF protection for outbound webhook URLs.

  In production, enforces HTTPS, blocks private IP literals at the URL layer,
  and resolves DNS to confirm the resolved address is also non-private.
  In other environments, only the URL syntax and scheme are validated so
  that local development and tests can target loopback hosts.
  """

  alias Tymeslot.Security.{DnsResolution, UrlValidation}

  @spec check(String.t()) :: :ok | {:error, atom() | String.t()}
  def check(url) do
    if production?() do
      with :ok <-
             UrlValidation.validate_http_url(url,
               block_private_ips: true,
               enforce_https: true
             ) do
        dns_resolver().check_private_ip(url, [])
      end
    else
      UrlValidation.validate_http_url(url)
    end
  end

  @spec dns_resolver() :: module()
  defp dns_resolver do
    Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)
  end

  defp production? do
    Application.get_env(:tymeslot, :environment) == :prod
  end
end
