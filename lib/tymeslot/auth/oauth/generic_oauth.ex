defmodule Tymeslot.Auth.OAuth.GenericOAuth do
  @moduledoc """
  Handles generic OAuth/OIDC authentication logic.

  Supports any OAuth2/OIDC-compliant identity provider (e.g., Keycloak,
  Lemonldap::NG, Authentik). Uses the `provider`/`provider_uid` columns
  on the user schema instead of provider-specific ID columns.
  """

  @behaviour Tymeslot.Auth.OAuth.ProviderBehaviour

  require Logger

  alias OAuth2.Client
  alias Tymeslot.Auth.OAuth.Helper

  @doc """
  Returns the generic OAuth authorization URL with secure state parameter.
  """
  @spec authorize_url(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def authorize_url(conn, redirect_uri) do
    {updated_conn, state} = oauth_helper().generate_and_store_state(conn)
    client = oauth_helper().build_oauth_client(:oauth, redirect_uri, state)
    scope = oauth_scope()
    authorize_url = Client.authorize_url!(client, scope: scope)
    {updated_conn, authorize_url}
  end

  @doc """
  Returns the generic OAuth callback URL.
  """
  @spec get_callback_url() :: String.t()
  def get_callback_url, do: oauth_helper().get_callback_url(:oauth)

  defp oauth_helper do
    Application.get_env(:tymeslot, :oauth_helper_module, Helper)
  end

  defp oauth_scope do
    config = Application.get_env(:tymeslot, :oauth_provider, [])
    Keyword.get(config, :scope, "openid email profile")
  end
end
