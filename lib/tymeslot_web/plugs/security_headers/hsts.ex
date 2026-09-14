defmodule TymeslotWeb.Plugs.SecurityHeaders.Hsts do
  @moduledoc """
  Builds the `strict-transport-security` header value from configuration.

  Separate from `TymeslotWeb.Plugs.SecurityHeadersPlug` so the plug can build
  the header once at compile time — it runs on every response — while every
  directive combination stays directly testable.

  `max-age` binds only the host that sends the header and is always emitted.
  The other two directives reach past it, and Core ships to self-hosters, so
  neither is on by default:

    * `includeSubDomains` forces *every* sibling subdomain of the operator's
      domain to HTTPS for the whole `max-age`. An operator installing at their
      apex would take an internal HTTP-only service on a sibling subdomain
      offline, with no clickthrough and no reason to suspect a scheduling app.
    * `preload` declares that domain eligible for the browser preload list,
      which is not our declaration to make on someone else's domain.

  A deployment that owns its whole domain opts in. Note that the preload list
  itself requires `includeSubDomains`, so `preload` alone is accepted but
  cannot achieve a preload.
  """

  @default_max_age 31_536_000

  # Ordered as the directives are conventionally written.
  @directives [include_subdomains: "includeSubDomains", preload: "preload"]

  @doc """
  Returns the header value for `config`, a keyword list accepting `:max_age`,
  `:include_subdomains` and `:preload`.

  Both directives default to `false` and `:max_age` to one year, so an empty
  config yields the host-only form.

      iex> TymeslotWeb.Plugs.SecurityHeaders.Hsts.header([])
      "max-age=31536000"

      iex> TymeslotWeb.Plugs.SecurityHeaders.Hsts.header(
      ...>   max_age: 600, include_subdomains: true, preload: true
      ...> )
      "max-age=600; includeSubDomains; preload"
  """
  @spec header(keyword()) :: String.t()
  def header(config) do
    max_age = Keyword.get(config, :max_age, @default_max_age)

    enabled = for {key, directive} <- @directives, Keyword.get(config, key, false), do: directive

    Enum.join(["max-age=#{max_age}" | enabled], "; ")
  end
end
