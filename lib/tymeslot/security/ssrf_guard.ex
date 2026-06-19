defmodule Tymeslot.Security.SsrfBlockedError do
  @moduledoc """
  Returned by `Tymeslot.Infrastructure.HTTPClient` when a request to a
  user-supplied host is refused by `Tymeslot.Security.SsrfGuard`.
  """

  defexception [:url, :reason]

  @impl Exception
  def message(%__MODULE__{url: url, reason: reason}) do
    "outbound request to #{inspect(url)} blocked by SSRF protection: #{inspect(reason)}"
  end
end

defmodule Tymeslot.Security.SsrfGuard do
  @moduledoc """
  Request-time SSRF validation for outbound HTTP requests to user-supplied
  hosts (CalDAV servers, self-hosted MiroTalk instances).

  Where `Tymeslot.Security.UrlValidation` runs at changeset/save time against
  the URL *string*, this guard runs immediately before the request leaves the
  application and additionally resolves the hostname via DNS, rejecting it when
  the resolved address falls in a private, loopback, or link-local range
  (including the 169.254.169.254 cloud-metadata endpoint).

  Running at request time is what closes the DNS-rebinding (TOCTOU) gap: a host
  that resolved to a public address when the integration was saved cannot later
  be re-pointed at an internal address and have a recurring sync follow it
  there. It mirrors the posture already enforced for outbound webhooks by
  `Tymeslot.Webhooks.SsrfValidator`.

  Enforcement is gated to `:prod` — the environment in which the managed SaaS
  and self-hosted deployments run — so that local development and tests can
  still target loopback CalDAV/video containers. Self-hosters who genuinely run
  an integration on a private network opt out via
  `config :tymeslot, :allow_private_ips_for_calendar, true`, the same bypass
  honoured at save time.
  """

  alias Tymeslot.Security.{DnsResolution, UrlValidation}

  @doc """
  Validates that `url` does not resolve to a private/local network address.

  Returns `:ok` when the request is permitted (public host, non-prod
  environment, or an explicit private-IP allowance) and `{:error, reason}`
  when it must be blocked.
  """
  @spec validate(String.t(), keyword()) :: :ok | {:error, atom() | String.t()}
  def validate(url, opts \\ []) do
    cond do
      Keyword.get(opts, :allow_private, allow_private_config?()) ->
        :ok

      not production?() ->
        :ok

      true ->
        with :ok <- UrlValidation.validate_http_url(url, block_private_ips: true) do
          dns_resolver().check_private_ip(url, [])
        end
    end
  end

  defp allow_private_config? do
    Application.get_env(:tymeslot, :allow_private_ips_for_calendar, false)
  end

  defp production? do
    Application.get_env(:tymeslot, :environment) == :prod
  end

  defp dns_resolver do
    Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)
  end
end
