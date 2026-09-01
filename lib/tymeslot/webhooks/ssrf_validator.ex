defmodule Tymeslot.Webhooks.SsrfValidator do
  @moduledoc """
  SSRF protection for outbound webhook URLs.

  In production, enforces HTTPS, blocks private IP literals at the URL layer,
  and resolves DNS to confirm the resolved address is also non-private.
  In other environments, only the URL syntax and scheme are validated so
  that local development and tests can target loopback hosts.

  Self-hosters whose webhook targets genuinely live on a private network opt
  out via `config :tymeslot, :allow_private_ips_for_webhooks, true`
  (`ALLOW_PRIVATE_IPS_FOR_WEBHOOKS=true`). This is the webhook-scoped sibling of
  `:allow_private_ips_for_calendar` and deliberately independent of it — relaxing
  calendar/video SSRF should not silently open outbound webhooks to internal
  hosts. When set, the guard falls back to syntax/scheme-only validation, the
  same posture used outside production.

  Note: a residual DNS-rebinding TOCTOU window exists between `check/1`
  (and each redirect-hop check in `Tymeslot.Webhooks.HttpDelivery`) and the
  TCP connect Finch performs afterwards, which re-resolves DNS independently.
  A short-TTL record can answer public here and private by the time Finch
  connects. See `deferred/2026-08-30-webhook-ssrf-dns-rebinding-toctou.md` for
  the tracked fix (connection-IP pinning).
  """

  alias Tymeslot.Security.{DnsResolution, UrlValidation}

  @spec check(String.t()) :: :ok | {:error, atom() | String.t()}
  def check(url) do
    if enforce?() do
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

  @doc """
  Whether the operator has opted out of webhook private-IP SSRF protection.

  Exposed so the webhook changeset validators and connection-test helpers read
  the opt-out from one place rather than each re-reading the config key.
  """
  @spec allow_private?() :: boolean()
  def allow_private? do
    Application.get_env(:tymeslot, :allow_private_ips_for_webhooks, false)
  end

  # Full DNS-resolving SSRF enforcement applies only in production and only
  # while the self-host opt-out is off.
  defp enforce? do
    production?() and not allow_private?()
  end

  @spec dns_resolver() :: module()
  defp dns_resolver do
    Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)
  end

  defp production? do
    Application.get_env(:tymeslot, :environment) == :prod
  end
end
