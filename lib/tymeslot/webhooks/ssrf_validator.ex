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

  `check_pinned/1` returns the addresses it approved so that
  `Tymeslot.Webhooks.HttpDelivery` can connect to one of them directly rather
  than letting Finch resolve the hostname a second time. That second resolution
  was the DNS-rebinding window: a short-TTL record could answer public here and
  loopback by the time the socket opened. See
  `Tymeslot.Security.ConnectionPinning` for the cases where pinning does not
  apply and the request still travels by hostname.
  """

  alias Tymeslot.Security.{DnsResolution, UrlValidation}

  @spec check(String.t()) :: :ok | {:error, atom() | String.t()}
  def check(url) do
    case check_pinned(url) do
      {:ok, _addresses} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Same verdict as `check/1`, but returns the addresses the check approved so
  the delivery can be pinned to one of them.

  `Tymeslot.Webhooks.HttpDelivery` uses this for both the initial URL and every
  redirect hop. An empty list means the URL was permitted on syntax alone
  (non-production, or the operator opt-out) and there is nothing to pin to.
  """
  @spec check_pinned(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, atom() | String.t()}
  def check_pinned(url) do
    if enforce?() do
      with :ok <-
             UrlValidation.validate_http_url(url,
               block_private_ips: true,
               enforce_https: true
             ) do
        resolve_public(dns_resolver(), url)
      end
    else
      with :ok <- UrlValidation.validate_http_url(url), do: {:ok, []}
    end
  end

  # A resolver that cannot hand back its addresses (a test double, typically)
  # still gets to make the verdict; the delivery simply goes unpinned.
  # `Code.ensure_loaded?/1` first: `function_exported?/3` answers false for a
  # module the VM has not loaded yet, which in dev and test is most of them.
  @spec resolve_public(module(), String.t()) ::
          {:ok, [:inet.ip_address()]} | {:error, atom() | String.t()}
  defp resolve_public(resolver, url) do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :resolve_public, 2) do
      resolver.resolve_public(url, [])
    else
      with :ok <- resolver.check_private_ip(url, []), do: {:ok, []}
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
