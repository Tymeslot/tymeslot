defmodule Tymeslot.Integrations.Shared.MicrosoftConfig do
  @moduledoc """
  Microsoft identity platform configuration for the Microsoft Graph
  integrations (Outlook calendar and Teams): client credentials, state
  secret, endpoints and the scope both request.

  Credentials are read through `Tymeslot.Integrations.Shared.OAuthConfig`
  (`:outlook_oauth` config, else `OUTLOOK_CLIENT_ID`,
  `OUTLOOK_CLIENT_SECRET`, `OUTLOOK_STATE_SECRET`).
  """

  @behaviour Tymeslot.Integrations.Shared.OAuthConfig

  alias Tymeslot.Integrations.Shared.OAuthConfig

  @base_url "https://login.microsoftonline.com/common/oauth2/v2.0"

  # Outlook calendar and Teams both work through calendar events, so they
  # request the same scope; `email` puts the account's address in the id token.
  @scope "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/User.Read offline_access openid profile email"

  @doc "The client id; raises when it is not configured."
  @spec client_id!() :: String.t()
  def client_id!, do: OAuthConfig.fetch!(:microsoft, :client_id)

  @doc "The client secret; raises when it is not configured."
  @spec client_secret!() :: String.t()
  def client_secret!, do: OAuthConfig.fetch!(:microsoft, :client_secret)

  @impl OAuthConfig
  def fetch_client_id, do: OAuthConfig.fetch(:microsoft, :client_id)

  @impl OAuthConfig
  def fetch_client_secret, do: OAuthConfig.fetch(:microsoft, :client_secret)

  @doc "The secret that signs OAuth `state`; raises when it is not configured."
  @spec state_secret() :: String.t()
  def state_secret, do: OAuthConfig.fetch!(:microsoft, :state_secret)

  @doc "The authorisation endpoint the browser is sent to."
  @spec authorize_url() :: String.t()
  def authorize_url, do: "#{@base_url}/authorize"

  @impl OAuthConfig
  @doc "The token endpoint for code exchange and refresh."
  def token_url, do: "#{@base_url}/token"

  @doc "The scope Outlook calendar and Teams request."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  The static Tenant ID used by Microsoft to identify all personal/consumer accounts.
  """
  @spec consumer_tenant_id() :: String.t()
  def consumer_tenant_id, do: "9188040d-6c67-4c5b-b112-36a304b66dad"
end
