defmodule Tymeslot.Auth.OAuth.Providers do
  @moduledoc """
  The social sign-in providers, as data. Everything that differs between
  GitHub, Google and the generic OAuth/OIDC provider (SSO) lives in
  `@providers`; the flow, the HTTP client and the account lookup read it
  rather than branching per provider.

  Per provider:

    * `:slug` - the URL segment (`/auth/github`) and the stored `provider`
    * `:name` - the name shown to users
    * `:setting` - the `AppSettings` key that switches it on, read at request
      time because an admin can toggle it without a restart
    * `:uid_field` - the user column holding the provider's stable user ID
    * `:uid_claims` - the userinfo keys that carry that ID, in order of
      preference
    * `:email` - where a verified email comes from: `{:claim, key, absent}`
      when the userinfo response carries `key: true` beside the email, or
      `{:emails_endpoint, url}` for GitHub's list of addresses. `absent` says
      what a response without the claim means: `:unverified`, or
      `:trusted_unless_required` for the generic provider, whose identity
      provider is the operator's own and often omits the claim (Authentik,
      Entra ID, some Keycloak setups). Setting
      `OAUTH_REQUIRE_EMAIL_VERIFIED_CLAIM=true` makes an absent claim count as
      unverified there too. An explicit `false` is always unverified.
    * `:auth_scheme` - the `Authorization` scheme for userinfo requests
    * `:authorize_params` - extra authorise-URL parameters
    * `:lookup` - the `UserQueries` function (and leading arguments) that
      finds the account by its provider ID; named rather than captured, so
      the table stays free of compile-time dependencies

  Endpoints, scope and client credentials come from `config/1`, since the
  generic provider's are configured at runtime.

  Every provider receives PKCE parameters: GitHub, Google and OIDC servers
  support S256, and RFC 6749 requires a server to ignore request parameters
  it does not recognise, so no per-provider switch is needed.
  """

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Integrations.Google.Endpoints, as: GoogleEndpoints

  @type provider :: :github | :google | :oauth

  @type config :: %{
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          authorize_url: String.t(),
          token_url: String.t(),
          userinfo_url: String.t(),
          scope: String.t()
        }

  @providers %{
    github: %{
      slug: "github",
      name: "GitHub",
      setting: :github_auth_enabled,
      uid_field: :github_user_id,
      uid_claims: ["id"],
      email: {:emails_endpoint, "https://api.github.com/user/emails"},
      auth_scheme: "token",
      authorize_params: %{},
      lookup: {:get_user_by_github_id, []}
    },
    google: %{
      slug: "google",
      name: "Google",
      setting: :google_auth_enabled,
      uid_field: :google_user_id,
      uid_claims: ["id"],
      email: {:claim, "verified_email", :unverified},
      auth_scheme: "Bearer",
      authorize_params: %{prompt: "select_account"},
      lookup: {:get_user_by_google_id, []}
    },
    oauth: %{
      slug: "oauth",
      name: "SSO",
      setting: :oauth_auth_enabled,
      uid_field: :provider_uid,
      uid_claims: ["sub"],
      email: {:claim, "email_verified", :trusted_unless_required},
      auth_scheme: "Bearer",
      authorize_params: %{},
      lookup: {:get_user_by_provider, ["oauth"]}
    }
  }

  # Display order of the sign-in buttons.
  @button_order [:google, :github, :oauth]

  @slugs Map.new(@providers, fn {provider, %{slug: slug}} -> {slug, provider} end)

  @doc """
  Resolves a URL segment or stored provider (`"github"`) to its atom.
  """
  @spec parse(term()) :: {:ok, provider()} | {:error, :unsupported_provider}
  def parse(slug) do
    case Map.fetch(@slugs, slug) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :unsupported_provider}
    end
  end

  @doc """
  The static description of `provider` (see the moduledoc).
  """
  @spec fetch!(provider()) :: map()
  def fetch!(provider), do: Map.fetch!(@providers, provider)

  @doc "The name shown to users."
  @spec name(provider()) :: String.t()
  def name(provider), do: fetch!(provider).name

  @doc "The callback path the provider redirects back to."
  @spec callback_path(provider()) :: String.t()
  def callback_path(provider), do: "/auth/#{fetch!(provider).slug}/callback"

  @doc "Whether the admin has switched sign-in with `provider` on."
  @spec enabled?(provider()) :: boolean()
  def enabled?(provider), do: AppSettings.get(fetch!(provider).setting) == true

  @doc """
  The enabled providers in button order, as `%{slug: _, name: _}`.
  """
  @spec enabled() :: [%{slug: String.t(), name: String.t()}]
  def enabled do
    for provider <- @button_order, enabled?(provider) do
      Map.take(fetch!(provider), [:slug, :name])
    end
  end

  @doc """
  Finds the account carrying `uid` as its ID at `provider`.
  """
  @spec find_user(provider(), String.t() | nil, module()) :: {:ok, map()} | {:error, :not_found}
  def find_user(_provider, uid, _repo) when not is_binary(uid) or uid == "",
    do: {:error, :not_found}

  def find_user(provider, uid, repo) do
    {function, leading} = fetch!(provider).lookup
    apply(UserQueries, function, leading ++ [uid, repo])
  end

  @doc """
  Endpoints, scope and client credentials for `provider`. The generic
  provider's come from `config :tymeslot, :oauth_provider`, and raise when a
  required one is missing.
  """
  @spec config(provider()) :: config()
  def config(:github) do
    %{
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      userinfo_url: "https://api.github.com/user",
      scope: "user:email"
    }
  end

  def config(:google) do
    %{
      client_id: System.get_env("GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
      authorize_url: GoogleEndpoints.authorize_url(),
      token_url: GoogleEndpoints.token_url(),
      userinfo_url: GoogleEndpoints.userinfo_url(),
      scope: "email profile"
    }
  end

  def config(:oauth) do
    config = Application.get_env(:tymeslot, :oauth_provider, [])
    required = [:client_id, :client_secret, :authorize_url, :token_url, :userinfo_url]

    case Enum.filter(required, &is_nil(config[&1])) do
      [] ->
        config
        |> Keyword.take(required)
        |> Map.new()
        |> Map.put(:scope, Keyword.get(config, :scope, "openid email profile"))

      missing ->
        raise "Generic OAuth config incomplete, missing keys: #{inspect(missing)}. " <>
                "Set the corresponding OAUTH_* environment variables."
    end
  end
end
