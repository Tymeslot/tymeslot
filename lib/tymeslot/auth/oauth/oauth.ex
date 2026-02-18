defmodule Tymeslot.Auth.OAuth.OAuth do
  @moduledoc """
  Handles Generic OAuth authentication logic.
  """
  @behaviour Tymeslot.Auth.OAuth.ProviderBehaviour
  require Logger

  alias OAuth2.Client
  alias Tymeslot.Auth.OAuth.{Authenticator, Helper}

  @doc """
  Gets OAuth URL for Generic OAuth provider.
  """
  @spec get_oauth_url(atom(), String.t() | nil) :: String.t() | {:error, term()}
  def get_oauth_url(_calling_app, _state) do
    # For testing, return a mock URL
    "https://sso.example.org/oauth2/authorize?client_id=test"
  end

  @doc """
  Returns the OAuth2 authorization URL with secure state parameter.

  Generates a secure state parameter, stores it in the session, and includes it in the OAuth URL.
  """
  @spec authorize_url(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def authorize_url(conn, redirect_uri) do
    {updated_conn, state} = oauth_helper().generate_and_store_state(conn)
    client = oauth_helper().build_oauth_client(:oauth, redirect_uri, state)
    scope = System.get_env("OAUTH_SCOPE") || "email profile"
    authorize_url = Client.authorize_url!(client, scope: scope)
    {updated_conn, authorize_url}
  end

  @doc """
  Handles the OAuth callback: validates state, exchanges code for token, and fetches user info.

  ## Parameters
    - conn: Plug.Conn.t()
    - code: String.t() - OAuth authorization code
    - state: String.t() - OAuth state parameter for CSRF protection
    - redirect_uri: String.t() - The redirect URI used in the authorization request

  ## Returns
    - {:ok, conn, user_info} - Successful authentication
    - {:error, conn, reason} - Authentication failed (e.g., invalid state)
  """
  @spec handle_callback(Plug.Conn.t(), String.t(), String.t(), String.t()) ::
          Plug.Conn.t()
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
  Returns the OAuth2 callback URL.
  """
  @spec get_callback_url() :: String.t()
  def get_callback_url, do: oauth_helper().get_callback_url(:oauth)

  @doc """
  Processes the user info returned from GitHub and returns a user map.
  """
  @spec process_user(map()) :: {:ok, map()} | {:error, any()}
  def process_user(user_info), do: oauth_helper().process_user(:oauth, user_info)

  @doc """
  Checks if the registration is complete for a OAuth user.
  """
  @spec registration_complete?(map()) :: boolean()
  def registration_complete?(user), do: oauth_helper().registration_complete?(:oauth, user)

  @doc """
  Complete Generic OAuth authentication flow.

  Handles the OAuth callback, processes the user information, creates a session
  if the registration is complete, or redirects to complete registration if needed.

  ## Parameters
    - conn: Plug.Conn.t()
    - code: String.t() - OAuth authorization code

  ## Returns
    - {:ok, conn, flash_message} - Successful authentication with complete registration
    - {:ok, conn, :incomplete_registration, params} - Successful auth but needs registration completion
    - {:error, conn, reason, flash_message} - Authentication failed
  """
  @spec authenticate(Plug.Conn.t(), String.t()) ::
          {:ok, Plug.Conn.t(), String.t()}
          | {:ok, Plug.Conn.t(), :incomplete_registration, map()}
          | {:error, Plug.Conn.t(), atom(), String.t()}
  def authenticate(conn, code) do
    Authenticator.authenticate(
      conn,
      code,
      :oauth,
      get_callback_url(),
      &process_user/1,
      &registration_complete?/1,
      fn user ->
        %{
          provider: "oauth",
          email: user.email,
          verified_email: user.is_verified,
          oauth_user_id: user.sub
        }
      end
    )
  end

  # Use dependency injection for the OAuth Helper
  defp oauth_helper do
    Application.get_env(:tymeslot, :oauth_helper_module, Helper)
  end
end
