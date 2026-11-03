defmodule TymeslotWeb.Analytics.Providers do
  @moduledoc """
  The single reading of `:analytics_providers`, for every surface that depends
  on it.

  The layout renders a loader script for each provider, and the CSP plug allows
  each provider's origin. Both take their answer from here, so a provider the
  layout renders always has its origin in the policy, and the policy never
  allows an origin no script loads from.

  Read at call time, not at compile time: SaaS sets the key in its
  `config/runtime.exs`, so a compile-time read would bake the build machine's
  value into the release image.
  """

  @type provider :: %{
          required(:provider) => :umami,
          required(:script_url) => String.t(),
          required(:website_id) => String.t(),
          optional(atom()) => any()
        }

  @doc """
  The configured providers that are complete enough to render: a known
  provider with a non-empty website id and an absolute http(s) or same-origin
  script URL. Anything else is dropped.
  """
  @spec all() :: [provider()]
  def all do
    case Application.get_env(:tymeslot, :analytics_providers) do
      providers when is_list(providers) -> Enum.filter(providers, &valid?/1)
      _unset -> []
    end
  end

  @doc """
  The distinct external origins (`scheme://host[:port]`) the valid providers
  load from. Same-origin script URLs contribute nothing; `'self'` covers them.
  """
  @spec origins() :: [String.t()]
  def origins do
    all()
    |> Enum.map(&origin(&1.script_url))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp valid?(%{provider: :umami, script_url: url, website_id: id})
       when is_binary(url) and is_binary(id) and url != "" and id != "" do
    String.starts_with?(url, ["https://", "http://", "/"])
  end

  defp valid?(_provider), do: false

  # A non-default port is kept: a CSP host source without one matches only
  # the scheme's default port, so dropping it would block the script.
  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _relative ->
        nil
    end
  end
end
