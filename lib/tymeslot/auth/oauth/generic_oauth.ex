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
  Handles the OAuth callback.
  """
  @spec handle_callback(Plug.Conn.t(), String.t(), String.t(), String.t()) ::
          Tymeslot.Auth.OAuth.HelperBehaviour.flow_result()
  def handle_callback(conn, code, state, _redirect_uri) do
    oauth_helper().handle_oauth_callback(conn, %{
      code: code,
      state: state,
      provider: :oauth,
      opts: [
        success_path: "/dashboard",
        login_path: "/?auth=login",
        registration_path: "/?auth=oauth_complete"
      ]
    })
  end

  @doc """
  Returns the generic OAuth callback URL.
  """
  @spec get_callback_url() :: String.t()
  def get_callback_url, do: oauth_helper().get_callback_url(:oauth)

  @doc """
  Processes the user info returned from the generic OAuth provider.
  """
  @spec process_user(map()) :: {:ok, map()} | {:error, any()}
  def process_user(user_info), do: oauth_helper().process_user(:oauth, user_info)

  @doc """
  Checks if the registration is complete for a generic OAuth user.
  """
  @spec registration_complete?(map()) :: boolean()
  def registration_complete?(user), do: oauth_helper().registration_complete?(:oauth, user)

  defp oauth_helper do
    Application.get_env(:tymeslot, :oauth_helper_module, Helper)
  end

  defp oauth_scope do
    config = Application.get_env(:tymeslot, :oauth_provider, [])
    Keyword.get(config, :scope, "openid email profile")
  end
end
