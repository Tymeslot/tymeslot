defmodule TymeslotWeb.OAuthCallbackHandler do
  @moduledoc """
  Generic OAuth callback handler that reduces duplication across OAuth controllers.

  This module provides a standardized way to handle OAuth callbacks for different
  providers, ensuring consistent error handling, rate limiting, and response formatting.
  """

  require Logger
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Controller
  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Dashboard.DashboardContext
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
  - `:success_redirect_path` - Optional override for the success redirect only
    (defaults to `:redirect_path`)
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
    success_redirect_path = Keyword.get(opts, :success_redirect_path, redirect_path)

    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        process_oauth_callback(
          conn,
          params,
          service_name,
          exchange_fun,
          create_fun,
          {redirect_path, success_redirect_path}
        )

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          ErrorFormatter.format_rate_limit_error("authentication"),
          redirect_path
        )
    end
  end

  # Private functions

  defp process_oauth_callback(
         conn,
         params,
         service_name,
         exchange_fun,
         create_fun,
         {redirect_path, success_redirect_path}
       ) do
    with {:ok, tokens} <- exchange_fun.(params),
         {:ok, result} <- create_fun.(tokens) do
      # Invalidate dashboard cache to reflect the new integration
      # Try to get user_id from either the result or tokens
      user_id = get_user_id(result, tokens)
      if user_id, do: DashboardContext.invalidate_integration_status(user_id)

      conn
      |> Controller.put_flash(
        :info,
        dgettext("dashboard_integrations", "%{service} connected successfully!",
          service: service_name
        )
      )
      |> Controller.redirect(to: success_redirect_path)
    else
      {:error, "access_denied"} ->
        service_atom =
          case String.downcase(service_name) do
            "github" -> :github
            "google" -> :google
            _other_service -> :unknown
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

      {:error, :calendar_scope_missing} ->
        Logger.info("OAuth callback rejected: calendar write scope not granted",
          service: service_name
        )

        conn
        |> Controller.put_flash(
          :error,
          dgettext(
            "dashboard_integrations",
            "%{service} wasn't connected because Calendar permission was not granted. Please try again and tick the box for \"See, edit, share, and permanently delete all the calendars you can access using Google Calendar\" - Tymeslot needs this to create meetings and Google Meet links.",
            service: service_name
          )
        )
        |> Controller.redirect(to: redirect_path)

      {:error, reason} ->
        Logger.error("OAuth callback failed", service: service_name, reason: inspect(reason))

        conn
        |> Controller.put_flash(
          :error,
          dgettext("dashboard_integrations", "Failed to connect %{service}. Please try again.",
            service: service_name
          )
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
