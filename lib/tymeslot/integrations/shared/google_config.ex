defmodule Tymeslot.Integrations.Shared.GoogleConfig do
  @moduledoc """
  Google OAuth configuration for the Google Calendar and Google Meet
  integrations: client credentials, state secret, endpoints and scopes.

  Credentials are read through `Tymeslot.Integrations.Shared.OAuthConfig`
  (`:google_oauth` config, else `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
  `GOOGLE_STATE_SECRET`). The endpoints are Google sign-in's too.
  """

  @behaviour Tymeslot.Integrations.Shared.OAuthConfig

  alias Tymeslot.Integrations.Shared.OAuthConfig

  @scopes %{
    openid: "openid",
    email: "email",
    calendar: "https://www.googleapis.com/auth/calendar",
    meet: "https://www.googleapis.com/auth/meetings.space.created"
  }

  @doc "The client id; raises when it is not configured."
  @spec client_id!() :: String.t()
  def client_id!, do: OAuthConfig.fetch!(:google, :client_id)

  @impl OAuthConfig
  def fetch_client_id, do: OAuthConfig.fetch(:google, :client_id)

  @impl OAuthConfig
  def fetch_client_secret, do: OAuthConfig.fetch(:google, :client_secret)

  @doc "The secret that signs OAuth `state`; raises when it is not configured."
  @spec state_secret() :: String.t()
  def state_secret, do: OAuthConfig.fetch!(:google, :state_secret)

  @doc "The authorisation endpoint the browser is sent to."
  @spec authorize_url() :: String.t()
  def authorize_url, do: "https://accounts.google.com/o/oauth2/v2/auth"

  @impl OAuthConfig
  @doc "The token endpoint for code exchange and refresh."
  def token_url, do: "https://oauth2.googleapis.com/token"

  @doc "The v1 userinfo endpoint; its response carries `verified_email`."
  @spec userinfo_url() :: String.t()
  def userinfo_url, do: "https://www.googleapis.com/oauth2/v1/userinfo"

  @doc "The endpoint that revokes a grant, given either of its tokens."
  @spec revoke_url() :: String.t()
  def revoke_url, do: "https://oauth2.googleapis.com/revoke"

  @doc """
  The scope string for a named scope; a string is taken as a scope already.
  """
  @spec scope(atom() | String.t()) :: String.t()
  def scope(name) when is_atom(name), do: Map.get(@scopes, name, to_string(name))
  def scope(scope) when is_binary(scope), do: scope
end
