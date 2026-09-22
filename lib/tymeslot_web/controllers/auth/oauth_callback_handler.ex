defmodule TymeslotWeb.OAuthCallbackHandler do
  @moduledoc """
  The one callback path for every calendar and video OAuth provider.

  A provider sends the browser back with either a `code` and `state`, an
  `error`, or something malformed. The success path checks the state belongs to
  the signed-in user, rate limits by IP, and hands the code to the owning
  context (`Calendar.complete_oauth/3` or `Video.complete_oauth/3`), which
  connects the integration and refreshes the dashboard's cached status. The
  error path turns the provider's error into a flash.

  What differs per provider lives in `@providers`: the name shown to the user,
  which context and provider the code belongs to, which secret signed the
  state, and whether the provider is Microsoft, whose errors can carry an
  admin-consent code worth explaining.
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.Controller
  alias Plug.Conn
  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Helpers.MicrosoftOAuth
  alias TymeslotWeb.Helpers.OAuthStateGuard

  @type provider_key :: :google_calendar | :outlook_calendar | :google_meet | :teams | :zoom

  # `domain` and `provider` name the context function and the provider it
  # takes; `state_provider` names the secret the state was signed with, which
  # Teams shares with Outlook and Google Meet with Google Calendar.
  @providers %{
    google_calendar: %{
      name: "Google Calendar",
      domain: :calendar,
      provider: :google,
      state_provider: :google,
      microsoft?: false
    },
    outlook_calendar: %{
      name: "Outlook Calendar",
      domain: :calendar,
      provider: :outlook,
      state_provider: :outlook,
      microsoft?: true
    },
    google_meet: %{
      name: "Google Meet",
      domain: :video,
      provider: :google_meet,
      state_provider: :google,
      microsoft?: false
    },
    teams: %{
      name: "Microsoft Teams",
      domain: :video,
      provider: :teams,
      state_provider: :outlook,
      microsoft?: true
    },
    zoom: %{
      name: "Zoom",
      domain: :video,
      provider: :zoom,
      state_provider: :zoom,
      microsoft?: false
    }
  }

  # Reasons the user can act on get their own message; anything else is a
  # generic failure worth an error-level log.
  @actionable_reasons [:calendar_scope_missing, :missing_teams_fields, :missing_zoom_account_id]

  @doc """
  Handles a provider's OAuth callback request and returns the redirected conn.
  """
  @spec handle(Conn.t(), map(), provider_key()) :: Conn.t()
  def handle(conn, params, provider_key) do
    handle_params(conn, params, Map.fetch!(@providers, provider_key))
  end

  defp handle_params(conn, %{"code" => code, "state" => state}, config) do
    case OAuthStateGuard.enforce_user_match(conn, state, config.state_provider) do
      {:ok, validated} -> rate_limited_connect(conn, code, state, validated[:return_to], config)
      {:error, _reason} -> reject(conn, config)
    end
  end

  defp handle_params(conn, %{"error" => error} = params, config) do
    description = Map.get(params, "error_description", "")

    Logger.warning("OAuth provider returned an error",
      provider: config.name,
      error: error,
      description: description
    )

    flash_and_redirect(
      conn,
      :error,
      provider_error_message(error, description, config),
      integrations_path(config)
    )
  end

  defp handle_params(conn, params, config) do
    Logger.warning("Invalid OAuth callback params",
      provider: config.name,
      params: inspect(OAuthStateGuard.redact_callback_params(params))
    )

    flash_and_redirect(
      conn,
      :error,
      dgettext("dashboard_integrations", "Invalid authentication response. Please try again."),
      integrations_path(config)
    )
  end

  defp rate_limited_connect(conn, code, state, return_to, config) do
    failure_path = return_to || integrations_path(config)

    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        connect(conn, code, state, {return_to, failure_path}, config)

      {:error, :rate_limited, _message} ->
        Logger.warning("Rate limit exceeded for OAuth callback", provider: config.name)

        flash_and_redirect(
          conn,
          :error,
          ErrorFormatter.format_rate_limit_error("authentication"),
          failure_path
        )
    end
  end

  defp connect(conn, code, state, {return_to, failure_path}, config) do
    case complete(config, code, state) do
      {:ok, _integration} ->
        flash_and_redirect(
          conn,
          :info,
          dgettext("dashboard_integrations", "%{service} connected successfully!",
            service: config.name
          ),
          return_to || success_path(config)
        )

      {:error, reason} ->
        log_failure(reason, config)
        flash_and_redirect(conn, :error, failure_message(reason, config), failure_path)
    end
  end

  defp complete(%{domain: :calendar, provider: provider}, code, state),
    do: Calendar.complete_oauth(provider, code, state)

  defp complete(%{domain: :video, provider: provider}, code, state),
    do: Video.complete_oauth(provider, code, state)

  defp log_failure(reason, config) when reason in @actionable_reasons do
    Logger.warning("OAuth callback rejected", provider: config.name, reason: reason)
  end

  defp log_failure(reason, config) do
    Logger.error("OAuth callback failed", provider: config.name, reason: inspect(reason))
  end

  defp failure_message(:calendar_scope_missing, config) do
    dgettext(
      "dashboard_integrations",
      "%{service} wasn't connected because Calendar permission was not granted. Please try again and tick the box for \"See, edit, share, and permanently delete all the calendars you can access using Google Calendar\" - Tymeslot needs this to create meetings and Google Meet links.",
      service: config.name
    )
  end

  defp failure_message(:missing_teams_fields, _config) do
    dgettext(
      "dashboard_integrations",
      "Missing required Microsoft Teams information. Please try again."
    )
  end

  defp failure_message(:missing_zoom_account_id, _config) do
    dgettext("dashboard_integrations", "Could not identify your Zoom account. Please try again.")
  end

  defp failure_message(_reason, config) do
    dgettext("dashboard_integrations", "Failed to connect %{service}. Please try again.",
      service: config.name
    )
  end

  defp provider_error_message(error, description, config) do
    cond do
      config.microsoft? and MicrosoftOAuth.microsoft_admin_consent_error?(description) ->
        dgettext(
          "dashboard_integrations",
          "Your Microsoft organisation requires admin approval before Tymeslot can be connected. Please ask your IT administrator to grant consent for the app."
        )

      error == "access_denied" ->
        dgettext("dashboard_integrations", "Authorization was denied. Please try again.")

      true ->
        dgettext("dashboard_integrations", "Authentication failed. Please try again.")
    end
  end

  defp reject(conn, config) do
    conn
    |> flash_and_redirect(
      :error,
      dgettext(
        "dashboard_integrations",
        "Authentication session mismatch. Please sign in and try again."
      ),
      integrations_path(config)
    )
    |> Conn.halt()
  end

  # A successful calendar connect lands on the calendar (unless the flow asked
  # to return somewhere specific, e.g. onboarding): the reward for connecting
  # is seeing the week fill in. Failures, and every video outcome, return to
  # the integrations tab, where retrying makes sense.
  defp success_path(%{domain: :calendar}), do: ~p"/dashboard"
  defp success_path(config), do: integrations_path(config)

  defp integrations_path(%{domain: :calendar}), do: ~p"/dashboard/integrations?tab=calendars"
  defp integrations_path(%{domain: :video}), do: ~p"/dashboard/integrations?tab=video"

  defp flash_and_redirect(conn, kind, message, path) do
    conn
    |> Controller.put_flash(kind, message)
    |> Controller.redirect(to: path)
  end
end
