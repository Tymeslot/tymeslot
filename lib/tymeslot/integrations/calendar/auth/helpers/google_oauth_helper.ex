defmodule Tymeslot.Integrations.Calendar.Google.OAuthHelper do
  @moduledoc """
  Helper module for Google Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Google Calendar integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CallbackPersistence
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.VideoRoomWorker

  @doc """
  Generates the OAuth authorization URL for Google Calendar.

  Now requests full calendar scope to support Google Meet creation.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri) do
    GoogleOAuthHelper.authorization_url(user_id, redirect_uri, [:calendar])
  end

  @doc """
  Generates the OAuth authorization URL for Google Calendar with specific scopes.

  Accepts a keyword list as the third argument. When a list of atoms/strings is
  given it is treated as scopes (backward compatible). When a keyword list is
  given, `:scopes` defaults to `[:calendar]` and other keys (e.g. `:return_to`)
  are forwarded to the shared helper.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t(), list(atom() | String.t()) | keyword()) ::
          String.t()
  def authorization_url(user_id, redirect_uri, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      scopes = Keyword.get(opts, :scopes, [:calendar])
      GoogleOAuthHelper.authorization_url(user_id, redirect_uri, scopes, opts)
    else
      GoogleOAuthHelper.authorization_url(user_id, redirect_uri, opts)
    end
  end

  @doc """
  Generates the OAuth authorization URL with explicit scopes *and* options.

  Used when reconnecting an existing integration: the caller fixes the scopes
  while `integration_id` and `login_hint` target the account already connected,
  so the user is not asked to pick one again and cannot connect the wrong one.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t(), list(atom() | String.t()), keyword()) ::
          String.t()
  def authorization_url(user_id, redirect_uri, scopes, opts)
      when is_list(scopes) and is_list(opts) do
    GoogleOAuthHelper.authorization_url(user_id, redirect_uri, scopes, opts)
  end

  @doc """
  Handles the OAuth callback for the user `state` (already verified) names,
  and creates or updates their calendar integration.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec handle_callback(String.t(), String.t(), State.validated()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour.callback_error()}
  def handle_callback(
        code,
        redirect_uri,
        %{user_id: user_id, integration_id: integration_id} = flow
      ) do
    with {:ok, tokens} <-
           GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri,
             code_verifier: flow[:code_verifier]
           ),
         :ok <- ensure_calendar_write_scope(tokens, user_id),
         {:ok, integration} <-
           CallbackPersistence.upsert("google", user_id, integration_id, tokens) do
      register_push_channel_async(integration)
      enqueue_pending_video_room_retries(integration.user_id)
      {:ok, integration}
    end
  end

  # Validates that Google returned a token whose granted scope grants calendar
  # event write access. Without it, downstream Google Meet creation will fail
  # with HTTP 403 (ACCESS_TOKEN_SCOPE_INSUFFICIENT) — so we reject the callback
  # before any database write happens.
  defp ensure_calendar_write_scope(%{scope: scope}, user_id) do
    if GoogleProvider.has_calendar_write_scope?(scope) do
      :ok
    else
      Logger.info("Google Calendar OAuth callback rejected: calendar write scope not granted",
        user_id: user_id,
        granted_scope: scope
      )

      {:error, :calendar_scope_missing}
    end
  end

  # After a successful (re-)connection, kick the user's confirmed upcoming
  # meetings whose video room creation was previously blocked. The Oban job's
  # 5-minute uniqueness window prevents duplicates with any in-flight retries.
  # Best-effort: failures are logged but must not fail the OAuth response.
  defp enqueue_pending_video_room_retries(user_id) do
    user_id
    |> MeetingListQueries.list_user_meetings_missing_video_rooms(DateTime.utc_now())
    |> Enum.each(&VideoRoomWorker.schedule_video_room_creation(&1.id))

    :ok
  rescue
    error ->
      ErrorTracking.report_error(error, __STACKTRACE__, %{user_id: user_id})
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec exchange_code_for_tokens(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code_for_tokens(code, redirect_uri, opts \\ []) do
    GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, opts)
  end

  @doc """
  Refreshes an access token using a refresh token.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec refresh_access_token(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def refresh_access_token(refresh_token, current_scope \\ nil, opts \\ []) do
    GoogleOAuthHelper.refresh_access_token(refresh_token, current_scope, opts)
  end

  # Private functions

  defp register_push_channel_async(integration) do
    # Always enqueue a sync job so the initial event backfill happens — this
    # path is independent of the webhook URL and works on self-hosted. The
    # worker detects the nil sync token and calls `bootstrap_sync/1`.
    enqueue_initial_sync(integration)

    case Application.get_env(:tymeslot, :webhook_base_url) do
      nil ->
        Logger.info(
          "Google push channel subscription skipped: WEBHOOK_BASE_URL not configured",
          integration_id: integration.id
        )

      _url ->
        Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
          case Config.google_calendar_api_module().register_push_channel(integration) do
            {:ok, _updated} ->
              Logger.info("Google push channel registered",
                integration_id: integration.id
              )

            {:error, reason} ->
              log_push_channel_failure(integration, reason)

            {:error, type, message} ->
              log_push_channel_failure(integration, {type, message})
          end
        end)
    end
  end

  defp log_push_channel_failure(integration, reason) do
    Logger.error("Google push channel registration failed",
      integration_id: integration.id,
      reason: LogFormat.reason(reason)
    )
  end

  defp enqueue_initial_sync(integration) do
    result =
      %{"calendar_integration_id" => integration.id}
      |> SyncGoogleCalendarWorker.new()
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue initial Google Calendar sync",
          integration_id: integration.id,
          error: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
