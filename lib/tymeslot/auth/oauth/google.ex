defmodule Tymeslot.Auth.OAuth.Google do
  @moduledoc """
  Handles Google OAuth authentication logic.
  """
  @behaviour Tymeslot.Auth.OAuth.ProviderBehaviour
  require Logger

  alias OAuth2.Client
  alias Tymeslot.Auth.OAuth.Helper

  @doc """
  Returns the Google OAuth2 authorization URL with secure state parameter.

  Generates a secure state parameter, stores it in the session, and includes it in the OAuth URL.
  """
  @spec authorize_url(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def authorize_url(conn, redirect_uri) do
    {updated_conn, state} = oauth_helper().generate_and_store_state(conn)
    client = oauth_helper().build_oauth_client(:google, redirect_uri, state)
    authorize_url = Client.authorize_url!(client, scope: "email profile", prompt: "select_account")
    {updated_conn, authorize_url}
  end

  @doc """
  Returns the Google OAuth2 callback URL.
  """
  @spec get_callback_url() :: String.t()
  def get_callback_url, do: oauth_helper().get_callback_url(:google)

  # Use dependency injection for the OAuth Helper
  defp oauth_helper do
    Application.get_env(:tymeslot, :oauth_helper_module, Helper)
  end
end
