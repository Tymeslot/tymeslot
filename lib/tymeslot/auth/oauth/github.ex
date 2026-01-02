defmodule Tymeslot.Auth.OAuth.GitHub do
  @moduledoc """
  Handles GitHub OAuth authentication logic.
  """
  require Logger

  alias OAuth2.Client
  alias Tymeslot.Auth.OAuth.{Authenticator, Helper}

  @doc """
  Gets OAuth URL for GitHub provider.
  """
  @spec get_oauth_url(atom(), String.t() | nil) :: String.t() | {:error, term()}
  def get_oauth_url(_calling_app, _state) do
    # For testing, return a mock URL
    "https://github.com/login/oauth/authorize?client_id=test&scope=user:email"
  end

  @doc """
  Returns the GitHub OAuth2 authorization URL with secure state parameter.

  Generates a secure state parameter, stores it in the session, and includes it in the OAuth URL.
  """
  @spec authorize_url(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def authorize_url(conn, redirect_uri) do
    {updated_conn, state} = oauth_helper().generate_and_store_state(conn)
    client = oauth_helper().build_oauth_client(:github, redirect_uri, state)
    authorize_url = Client.authorize_url!(client, scope: "user:email")
    {updated_conn, authorize_url}
  end

  @doc """
  Returns the GitHub OAuth2 authorization URL (legacy function without state).

  This function is kept for backward compatibility but should be avoided.
  Use authorize_url/2 with connection and state parameter instead.
  """
  @spec authorize_url(String.t()) :: String.t()
  def authorize_url(redirect_uri) do
    client = oauth_helper().build_oauth_client(:github, redirect_uri, "")
    Client.authorize_url!(client, scope: "user:email")
  end

  @doc """
  Handles the OAuth callback: exchanges code for token and fetches user info.
  """
  @spec handle_callback(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def handle_callback(code, redirect_uri) do
    client = oauth_helper().build_oauth_client(:github, redirect_uri, "")

    with {:ok, client} <- oauth_helper().exchange_code_for_token(client, code),
         {:ok, user_info} <- oauth_helper().get_user_info(client, :github) do
      {:ok, user_info}
    else
      err -> {:error, err}
    end
  end

  @doc """
  Returns the GitHub OAuth2 callback URL.
  """
  @spec get_callback_url() :: String.t()
  def get_callback_url, do: oauth_helper().get_callback_url(:github)

  @doc """
  Processes the user info returned from GitHub and returns a user map.
  """
  @spec process_user(map()) :: {:ok, map()} | {:error, any()}
  def process_user(user_info), do: oauth_helper().process_user(:github, user_info)

  @doc """
  Checks if the registration is complete for a GitHub user.
  """
  @spec registration_complete?(map()) :: boolean()
  def registration_complete?(user), do: oauth_helper().registration_complete?(:github, user)

  @doc """
  Complete GitHub OAuth authentication flow.

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
      :github,
      get_callback_url(),
      &process_user/1,
      &registration_complete?/1,
      fn user ->
        %{
          provider: "github",
          email: user.email,
          verified_email: user.is_verified,
          github_user_id: user.github_user_id
        }
      end
    )
  end

  # Use dependency injection for the OAuth Helper
  defp oauth_helper do
    Application.get_env(:tymeslot, :oauth_helper_module, Helper)
  end
end
