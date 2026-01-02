defmodule TymeslotWeb.OAuthCallbackHandler do
  @moduledoc """
  Generic OAuth callback handler that reduces duplication across OAuth controllers.

  This module provides a standardized way to handle OAuth callbacks for different
  providers, ensuring consistent error handling, rate limiting, and response formatting.
  """

  require Logger
  alias Phoenix.Controller
  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.AuthControllerHelpers
  alias TymeslotWeb.Helpers.ClientIP

  @type callback_opts :: [
          service_name: String.t(),
          exchange_fun: (map() -> {:ok, map()} | {:error, any()}),
          create_fun: (map() -> {:ok, any()} | {:error, any()}),
          redirect_path: String.t(),
          rate_limit_key: String.t(),
          rate_limit_max: integer(),
          rate_limit_window: integer()
        ]

  @doc """
  Handles OAuth callback with standardized error handling and rate limiting.

  ## Options
  - `:service_name` - The name of the OAuth service (e.g., "GitHub", "Google")
  - `:exchange_fun` - Function to exchange code for tokens
  - `:create_fun` - Function to create/update the integration
  - `:redirect_path` - Path to redirect to after success/failure
  - `:rate_limit_key` - Key for rate limiting (default: "oauth_callback")
  - `:rate_limit_max` - Maximum attempts allowed (default: 10)
  - `:rate_limit_window` - Rate limit window in ms (default: 60_000)

  ## Examples

      handle_callback(conn, params, 
        service_name: "GitHub",
        exchange_fun: &GitHub.exchange_code/1,
        create_fun: &create_github_integration/1,
        redirect_path: "/dashboard/integrations"
      )
  """
  @spec handle_callback(Plug.Conn.t(), map(), callback_opts()) :: Plug.Conn.t()
  def handle_callback(conn, params, opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    exchange_fun = Keyword.fetch!(opts, :exchange_fun)
    create_fun = Keyword.fetch!(opts, :create_fun)
    redirect_path = Keyword.fetch!(opts, :redirect_path)

    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        process_oauth_callback(
          conn,
          params,
          service_name,
          exchange_fun,
          create_fun,
          redirect_path
        )

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          ErrorFormatter.format_rate_limit_error("authentication"),
          redirect_path
        )
    end
  end

  @doc """
  Handles OAuth callback for authentication flows (login/signup).

  Similar to `handle_callback/3` but designed for authentication flows where
  the user is logging in or signing up via OAuth.
  """
  @spec handle_auth_callback(Plug.Conn.t(), map(), callback_opts()) :: Plug.Conn.t()
  def handle_auth_callback(conn, params, opts) do
    # Add authentication-specific defaults
    opts =
      Keyword.merge(
        [
          rate_limit_key: "oauth_auth_callback",
          redirect_path: Config.success_redirect_path()
        ],
        opts
      )

    handle_callback(conn, params, opts)
  end

  @doc """
  Handles the OAuth request initiation with state generation and rate limiting.

  ## Options
  - `:service_name` - The name of the OAuth service
  - `:authorize_url_fun` - Function to generate the authorization URL
  - `:rate_limit_key` - Key for rate limiting (default: "oauth_initiation")
  - `:rate_limit_max` - Maximum attempts allowed (default: 5)
  - `:rate_limit_window` - Rate limit window in ms (default: 300_000)
  - `:error_redirect` - Path to redirect on error (default: "/")
  """
  @spec initiate_oauth(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def initiate_oauth(conn, opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    authorize_url_fun = Keyword.fetch!(opts, :authorize_url_fun)

    error_redirect = Keyword.get(opts, :error_redirect, "/")

    case RateLimiter.check_oauth_initiation_rate_limit(ClientIP.get(conn)) do
      :ok ->
        case authorize_url_fun.(conn) do
          {:ok, updated_conn, authorize_url} ->
            Controller.redirect(updated_conn, external: authorize_url)

          {:error, reason} ->
            Logger.error("Failed to generate #{service_name} OAuth URL: #{inspect(reason)}")

            conn
            |> Controller.put_flash(
              :error,
              "Failed to initiate #{service_name} authentication."
            )
            |> Controller.redirect(to: error_redirect)
        end

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          ErrorFormatter.format_rate_limit_error("OAuth"),
          error_redirect
        )
    end
  end

  # Private functions

  defp process_oauth_callback(conn, params, service_name, exchange_fun, create_fun, redirect_path) do
    with {:ok, tokens} <- exchange_fun.(params),
         {:ok, result} <- create_fun.(tokens) do
      # Invalidate dashboard cache to reflect the new integration
      # Try to get user_id from either the result or tokens
      user_id = get_user_id(result, tokens)
      if user_id, do: DashboardContext.invalidate_integration_status(user_id)

      conn
      |> Controller.put_flash(:info, "#{service_name} connected successfully!")
      |> Controller.redirect(to: redirect_path)
    else
      {:error, "access_denied"} ->
        service_atom =
          case String.downcase(service_name) do
            "github" -> :github
            "google" -> :google
            _ -> :unknown
          end

        conn
        |> Controller.put_flash(
          :error,
          ErrorFormatter.format_oauth_error(
            service_atom,
            "access_denied"
          )
        )
        |> Controller.redirect(to: redirect_path)

      {:error, reason} ->
        Logger.error("#{service_name} OAuth callback failed: #{inspect(reason)}")

        conn
        |> Controller.put_flash(
          :error,
          "Failed to connect #{service_name}. Please try again."
        )
        |> Controller.redirect(to: redirect_path)
    end
  end

  # Helper function to extract user_id from result or tokens
  defp get_user_id(result, tokens) do
    cond do
      # Check if result is a struct with user_id field
      is_map(result) && Map.has_key?(result, :user_id) -> result.user_id
      # Check if tokens has user_id
      is_map(tokens) && Map.has_key?(tokens, :user_id) -> tokens.user_id
      # Default case
      true -> nil
    end
  end
end
