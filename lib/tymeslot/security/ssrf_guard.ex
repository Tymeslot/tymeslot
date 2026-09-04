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
  application and additionally resolves the hostname via DNS (all A and AAAA
  records), rejecting it when any resolved address falls in a private, loopback,
  or link-local range (including the 169.254.169.254 cloud-metadata endpoint).

  **Connection pinning:** validating a hostname and then handing the URL string
  to Req/Finch would let Finch resolve that name a second time when it opens the
  socket, and a short-TTL record can answer public to the check and loopback to
  the connect. `validate_pinned/2` therefore returns the addresses it approved,
  and `Tymeslot.Infrastructure.HTTPClient` connects to one of them with the
  original hostname preserved for TLS and routing — see
  `Tymeslot.Security.ConnectionPinning`, which also documents the cases where
  pinning cannot apply and the request still travels by hostname. The
  multi-record variant of DNS-based SSRF is closed by checking every returned
  record before any of them is used.

  Enforcement is gated to `:prod` — the environment in which the managed SaaS
  and self-hosted deployments run — so that local development and tests can
  still target loopback CalDAV/video containers. Self-hosters who genuinely run
  an integration on a private network opt out per subsystem:

    * calendar — `config :tymeslot, :allow_private_ips_for_calendar, true`
      (`ALLOW_PRIVATE_IPS_FOR_CALENDAR=true`), read by `allow_private_for_calendar?/0`
    * video — `config :tymeslot, :allow_private_ips_for_video, true`
      (`ALLOW_PRIVATE_IPS_FOR_VIDEO=true`), read by `allow_private_for_video?/0`

  Both bypasses are honoured at save time as well as at request time, so a URL
  the operator is allowed to reach is also a URL they are allowed to store.
  """

  alias Tymeslot.Security.{DnsResolution, UrlValidation}

  @doc """
  Validates that `url` does not resolve to a private/local network address.

  Returns `:ok` when the request is permitted (public host, non-prod
  environment, or an explicit private-IP allowance) and `{:error, reason}`
  when it must be blocked.

  The allowance defaults to the calendar opt-out; video call sites pass
  `allow_private: allow_private_for_video?()` so the two subsystems can be
  relaxed independently.
  """
  @spec validate(String.t(), keyword()) :: :ok | {:error, atom() | String.t()}
  def validate(url, opts \\ []) do
    case validate_pinned(url, opts) do
      {:ok, _addresses} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Same verdict as `validate/2`, but returns the addresses the check approved.

  Callers that open the connection themselves should use this and pin to one of
  the returned addresses via `Tymeslot.Security.ConnectionPinning`: validating a
  hostname and then letting Finch resolve it again leaves the DNS-rebinding
  window this module's moduledoc describes.

  An empty list means no address was resolved because none needed to be — the
  environment or an operator opt-out permitted the request on syntax alone —
  and there is correspondingly nothing to pin to.
  """
  @spec validate_pinned(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, atom() | String.t()}
  def validate_pinned(url, opts \\ []) do
    cond do
      Keyword.get(opts, :allow_private, allow_private_for_calendar?()) ->
        {:ok, []}

      not production?() ->
        {:ok, []}

      true ->
        with :ok <- UrlValidation.validate_http_url(url, block_private_ips: true) do
          resolve_public(dns_resolver(), url)
        end
    end
  end

  # A resolver that cannot hand back its addresses (a test double, typically)
  # still gets to make the verdict; the request simply goes unpinned.
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
  Whether the operator has opted out of calendar private-IP SSRF protection.

  Exposed so the save-time validators (`CredentialFields`, the
  `CalendarIntegrationSchema` changeset) and the provider-level URL and
  discovery checks read the opt-out from one place rather than each re-reading
  the config key. Without that, the request-time guard and the paths that
  persist a URL can disagree, and the operator-facing switch silently does
  nothing because a URL it permits can never be saved.

  This is the calendar-scoped sibling of
  `Tymeslot.Webhooks.SsrfValidator.allow_private?/0`.
  """
  @spec allow_private_for_calendar?() :: boolean()
  def allow_private_for_calendar? do
    Application.get_env(:tymeslot, :allow_private_ips_for_calendar, false)
  end

  @doc """
  Whether the operator has opted out of video private-IP SSRF protection.

  Video is its own subsystem: a self-hoster running MiroTalk or their own
  meeting server on an internal network should not have to relax calendar SSRF
  to reach it. `ALLOW_PRIVATE_IPS_FOR_CALENDAR` nevertheless still satisfies
  video, because it shipped documented as covering both and revoking that would
  silently break the deployments already relying on it.
  """
  @spec allow_private_for_video?() :: boolean()
  def allow_private_for_video? do
    Application.get_env(:tymeslot, :allow_private_ips_for_video, false) or
      allow_private_for_calendar?()
  end

  defp production? do
    Application.get_env(:tymeslot, :environment) == :prod
  end

  defp dns_resolver do
    Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)
  end
end
