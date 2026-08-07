defmodule Tymeslot.Integrations.Video.OAuth do
  @moduledoc """
  Authorisation and reconnect URLs for the OAuth-backed video providers.

  Three providers, one flow: build a callback URL, ask the provider's helper
  for an authorisation URL, and turn a misconfiguration into a message naming
  the environment variable the operator has to set.

  That last part used to be three near-identical clause ladders differing only
  in a brand name and an env-var prefix, which is what `@providers` replaces.
  The messages are operator-facing and name concrete variables, so they are the
  kind of text that is easy to get subtly wrong in one copy and not the others.

  What is *not* tabled is the call into each helper: Google needs its scopes
  passed explicitly and Teams and Zoom do not, so those keep a clause each
  rather than being forced into a shared shape.
  """

  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias TymeslotWeb.Endpoint

  @typedoc "A video provider that authenticates over OAuth."
  @type provider :: :google_meet | :teams | :zoom

  # `label` is the brand named in operator-facing errors; `env_prefix` is the
  # environment-variable prefix for that provider's credentials; `callback` is
  # the path segment in its OAuth redirect URI. Microsoft's variables are
  # prefixed OUTLOOK rather than TEAMS because the two share one app
  # registration.
  @providers %{
    google_meet: %{label: "Google", env_prefix: "GOOGLE", callback: "google"},
    teams: %{label: "Microsoft", env_prefix: "OUTLOOK", callback: "teams"},
    zoom: %{label: "Zoom", env_prefix: "ZOOM", callback: "zoom"}
  }

  @google_scopes [:calendar, :meet]

  @doc """
  Whether this provider authenticates over OAuth.
  """
  @spec supported?(atom()) :: boolean()
  def supported?(provider), do: Map.has_key?(@providers, provider)

  @doc """
  Builds an authorisation URL to start a fresh connection.
  """
  @spec authorization_url(provider(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def authorization_url(provider, user_id), do: build(provider, user_id, [])

  @doc """
  Builds an authorisation URL for reconnecting an existing integration.

  `opts` carries the `integration_id` and `login_hint` that let the provider
  target the account already connected, rather than asking the user to pick one
  again and risk connecting the wrong one.
  """
  @spec reconnect_url(provider(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def reconnect_url(provider, user_id, opts), do: build(provider, user_id, opts)

  defp build(provider, user_id, opts) do
    case Map.fetch(@providers, provider) do
      {:ok, config} -> {:ok, url_for(provider, user_id, redirect_uri(config), opts)}
      :error -> {:error, "Provider does not support OAuth"}
    end
  rescue
    error -> {:error, format_error(provider, error)}
  end

  defp redirect_uri(%{callback: callback}),
    do: "#{Endpoint.url()}/auth/#{callback}/video/callback"

  # Each provider's helper takes its options last; Google additionally needs
  # its scopes stated explicitly, which is the only shape difference worth a
  # clause each.
  defp url_for(:google_meet, user_id, redirect_uri, opts) do
    google_helper().authorization_url(user_id, redirect_uri, @google_scopes, opts)
  end

  defp url_for(:teams, user_id, redirect_uri, opts) do
    teams_helper().authorization_url(user_id, redirect_uri, opts)
  end

  defp url_for(:zoom, user_id, redirect_uri, opts) do
    zoom_helper().authorization_url(user_id, redirect_uri, opts)
  end

  # Every provider's helper raises the same three misconfigurations, differing
  # only in the brand prefixing the message, so matching on the suffix keeps one
  # ladder instead of three.
  defp format_error(provider, %RuntimeError{message: message} = error) do
    %{label: label, env_prefix: prefix} = @providers[provider]

    cond do
      String.ends_with?(message, "State Secret not configured") ->
        "#{label} OAuth is not configured. Please set #{prefix}_CLIENT_ID, " <>
          "#{prefix}_CLIENT_SECRET, and #{prefix}_STATE_SECRET environment variables."

      String.ends_with?(message, "Client ID not configured") ->
        "#{label} OAuth is not configured. Please set #{prefix}_CLIENT_ID environment variable."

      String.ends_with?(message, "Client Secret not configured") ->
        "#{label} OAuth is not configured. Please set #{prefix}_CLIENT_SECRET environment variable."

      true ->
        generic_error(label, error)
    end
  end

  defp format_error(provider, error), do: generic_error(@providers[provider].label, error)

  defp generic_error(label, error),
    do: "Failed to setup #{label} OAuth: #{Exception.message(error)}"

  defp google_helper do
    Application.get_env(:tymeslot, :google_calendar_oauth_helper, GoogleOAuthHelper)
  end

  defp teams_helper do
    Application.get_env(:tymeslot, :teams_oauth_helper, TeamsOAuthHelper)
  end

  defp zoom_helper do
    Application.get_env(:tymeslot, :zoom_oauth_helper, ZoomOAuthHelper)
  end
end
