defmodule Tymeslot.Auth.OAuth.Authenticator do
  @moduledoc """
  Shared OAuth authentication flow for GitHub, Google and Generic OAuth providers.

  Handles the common pattern of exchanging codes, fetching user info,
  processing users, and creating sessions or returning registration params.
  """

  require Logger

  alias Tymeslot.Auth.Session

  @type provider :: :github | :google | :oauth
  @type registration_params :: %{
          provider: String.t(),
          email: String.t(),
          verified_email: boolean(),
          github_user_id: integer() | nil,
          google_user_id: integer() | nil,
          oauth_user_id: String.t() | nil
        }

  @doc """
  Complete OAuth authentication flow.

  Handles the OAuth callback, processes the user information, creates a session
  if the registration is complete, or returns registration params if needed.

  ## Parameters
    - conn: Plug.Conn.t()
    - code: String.t() - OAuth authorization code
    - provider: atom() - OAuth provider (:github, :google or :oauth)
    - callback_url: String.t() - OAuth callback URL
    - process_user_fun: function - Function to process user info (provider-specific)
    - registration_complete_fun: function - Function to check if registration is complete
    - build_registration_params_fun: function - Function to build registration params from user

  ## Returns
    - {:ok, conn, flash_message} - Successful authentication with complete registration
    - {:ok, conn, :incomplete_registration, params} - Successful auth but needs registration completion
    - {:error, conn, reason, flash_message} - Authentication failed
  """
  @spec authenticate(
          Plug.Conn.t(),
          String.t(),
          provider(),
          String.t(),
          (map() -> {:ok, map()} | {:error, any()}),
          (map() -> boolean()),
          (map() -> registration_params())
        ) ::
          {:ok, Plug.Conn.t(), String.t()}
          | {:ok, Plug.Conn.t(), :incomplete_registration, registration_params()}
          | {:error, Plug.Conn.t(), atom(), String.t()}
  def authenticate(
        conn,
        code,
        provider,
        callback_url,
        process_user_fun,
        registration_complete_fun,
        build_registration_params_fun
      ) do
    client = client_module().build(provider, callback_url, "")
    provider_name = provider |> to_string() |> String.capitalize()

    with {:ok, client} <- client_module().exchange_code_for_token(client, code),
         {:ok, user_info} <- client_module().get_user_info(client, provider),
         {:ok, user} <- process_user_fun.(user_info) do
      # If account is complete, log them in
      if registration_complete_fun.(user) do
        case session_module().create_session(conn, user) do
          {:ok, conn, _token} ->
            {:ok, conn, "Successfully signed in with #{provider_name}."}

          {:error, reason, _message} ->
            Logger.error("Failed to create session after OAuth auth",
              provider: provider_name,
              reason: inspect(reason)
            )

            {:error, conn, :session_creation_failed,
             "Authentication succeeded but session creation failed."}
        end
      else
        # Otherwise, return data for complete registration
        registration_params = build_registration_params_fun.(user)
        {:ok, conn, :incomplete_registration, registration_params}
      end
    else
      {:error, %OAuth2.Error{} = error} ->
        Logger.error("OAuth error", provider: provider_name, error: inspect(error))
        {:error, conn, :oauth_error, "Failed to authenticate with #{provider_name}."}

      {:error, reason} ->
        Logger.error("OAuth authentication error",
          provider: provider_name,
          reason: inspect(reason)
        )

        {:error, conn, :authentication_error,
         "An error occurred during #{provider_name} authentication."}
    end
  end

  # Use dependency injection for the Client and Session modules
  defp client_module do
    Application.get_env(:tymeslot, :oauth_client_module, Tymeslot.Auth.OAuth.Client)
  end

  defp session_module do
    Application.get_env(:tymeslot, :session_module, Session)
  end
end
