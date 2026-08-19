defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProvider do
  @moduledoc """
  Google Meet video conferencing provider implementation.

  This provider creates Google Meet links via the **Google Meet REST API**
  (`meet.googleapis.com/v2/spaces`), which provisions a standalone meeting
  space. Crucially, a space is *not* a calendar event — so connecting Google
  Meet no longer writes a second event into the user's Google Calendar
  alongside the booking event held on their own calendar provider
  (Radicale/Outlook/Google). This avoids the duplicate-event and
  orphaned-event problems of the previous approach, which created a throwaway
  Google Calendar event purely to harvest the Meet link.

  Requires the `https://www.googleapis.com/auth/meetings.space.created` OAuth
  scope **and** the *Google Meet API* enabled on the Google Cloud project — the
  scope alone is not sufficient (the API returns `403 SERVICE_DISABLED` until
  the API is enabled in the Cloud console).
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.OAuthCredentials
  alias Tymeslot.Integrations.Video.RoomData

  @capabilities Capabilities.new!(
                  recording: true,
                  screen_sharing: true,
                  waiting_room: false,
                  max_participants: 250,
                  dial_in: true,
                  chat: true,
                  breakout_rooms: true
                )

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :google_meet

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Google Meet"

  # A per-actor bucket shared across every OAuth-backed provider: the test
  # itself rides on a token that is already scarce, but without a charge
  # here it is unbounded and can burn the instance-wide OAuth quota shared
  # by every user.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def connection_test_bucket, do: :oauth

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def config_schema do
    %{
      access_token: %{type: :string, required: true, description: "Google OAuth access token"},
      refresh_token: %{type: :string, required: true, description: "Google OAuth refresh token"},
      token_expires_at: %{type: :datetime, required: true, description: "Token expiration time"}
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def validate_config(config) do
    ProviderConfigHelper.validate_required_fields(config, [
      :access_token,
      :refresh_token,
      :token_expires_at
    ])
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def capabilities, do: @capabilities

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Google Meet space")

    case precheck_create_meeting_room(config) do
      {:ok, valid_token} ->
        finish_create_meeting_room(valid_token, config)

      {:provider_error, reason} ->
        log_create_meeting_room_error(reason)
        {:error, reason}

      {:error, reason} = error ->
        log_create_meeting_room_error(reason)
        error
    end
  end

  @doc false
  # Pre-flight phase for `ProviderAdapter`'s circuit-breaker split (see the
  # comment on `ProviderAdapter.with_breaker/2`). Runs before the shared
  # Google Meet breaker is ever asked for permission.
  #
  # `ensure_valid_token/1` is network I/O, but against Google's OAuth host
  # rather than the Meet API, and its failures are classified before they
  # reach the breaker: a rejected/expired grant is the tenant's problem
  # (`{:error, _}`, bypasses the breaker entirely), while anything else — a
  # timeout or 5xx from the OAuth host — comes back as `{:provider_error, _}`
  # so the caller can still let the breaker witness it.
  @spec precheck_create_meeting_room(map()) ::
          {:ok, map()} | {:error, term()} | {:provider_error, term()}
  def precheck_create_meeting_room(config) do
    classify_token_result(ensure_valid_token(config))
  end

  @doc false
  # The actual outbound Meet API call, meant to run behind the shared
  # breaker. Takes the refreshed config `precheck_create_meeting_room/1`
  # already resolved, so it never repeats the OAuth round-trip. The original
  # `config` argument is unused: Meet space creation needs no tenant data
  # beyond the access token already embedded in `valid_token`.
  @spec finish_create_meeting_room(map(), map()) :: {:ok, RoomData.t()} | {:error, term()}
  def finish_create_meeting_room(valid_token, _config) do
    with {:ok, space} <- create_meet_space(valid_token),
         {:ok, room_data} <- extract_space_data(space) do
      Logger.info("Successfully created Google Meet space", room_id: room_data.room_id)
      {:ok, room_data}
    else
      {:error, reason} = error ->
        log_create_meeting_room_error(reason)
        error
    end
  end

  defp log_create_meeting_room_error(reason) do
    Logger.error("Failed to create Google Meet space", reason: Redactor.redact(reason))
  end

  # A rejected/expired grant (`invalid_grant`, `invalid_client`,
  # `access_denied`) is the tenant's credential, not Meet's availability —
  # `BreakerOutcome.permanent_credential_error?/1` shares this rule with
  # `HealthCheck.ResponseHandler`'s reauth fast-path (Google refreshes
  # through the shared `ErrorParser.build_message/3`, same as Zoom and
  # Teams). Anything else (network error, an unrecognised HTTP status) is
  # handed back for the breaker to witness.
  defp classify_token_result({:ok, _config} = ok), do: ok

  defp classify_token_result({:error, reason} = error) do
    if BreakerOutcome.permanent_credential_error?(reason),
      do: error,
      else: {:provider_error, reason}
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def delete_meeting_room(space_id, config) when is_binary(space_id) and space_id != "" do
    Logger.info("Ending active Google Meet conference on cancellation", room_id: space_id)

    case ensure_valid_token(config) do
      {:ok, valid_token} -> end_active_conference(valid_token, space_id)
      {:error, _reason} = error -> error
    end
  end

  def delete_meeting_room(_space_id, _config), do: :ok

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, participant_email, role, _meeting_time) do
    base_url = room_data.meeting_url

    if base_url do
      # Add participant info as URL parameters
      params = %{
        "authuser" => participant_email,
        "uname" => participant_name
      }

      params = if role == "organizer", do: Map.put(params, "role", "host"), else: params

      query_string = URI.encode_query(params)
      join_url = "#{base_url}?#{query_string}"

      Logger.debug("Created Google Meet join URL",
        participant: participant_name,
        role: role,
        room_id: room_data.room_id
      )

      {:ok, join_url}
    else
      {:error, "Missing meeting URL in room data"}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) and meeting_url != "" do
    uri = URI.parse(meeting_url)

    if uri.host == "meet.google.com" and uri.path do
      case String.split(uri.path, "/") do
        [_first, meeting_code] when meeting_code != "" -> meeting_code
        _other -> nil
      end
    else
      nil
    end
  rescue
    error ->
      Logger.warning("Failed to extract Google Meet room id from meeting URL",
        error: Exception.message(error)
      )

      nil
  end

  def extract_room_id(_url), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    uri.host == "meet.google.com" and
      is_binary(uri.path) and
      String.length(uri.path) > 1 and
      String.match?(uri.path, ~r|^/[a-z]{3}-[a-z]{4}-[a-z]{3}$|)
  rescue
    error ->
      Logger.warning("Failed to validate Google Meet meeting URL",
        error: Exception.message(error)
      )

      false
  end

  def valid_meeting_url?(_url), do: false

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    Logger.info("Testing Google Meet connection")

    with {:ok, valid_token} <- ensure_valid_token(config),
         {:ok, _calendar_list} <- get_calendar_list(valid_token) do
      {:ok, dgettext("dashboard_integrations", "Google Meet connected successfully!")}
    else
      {:error, reason} ->
        Logger.error("Google Meet connection test failed", reason: Redactor.redact(reason))

        {:error,
         dgettext("dashboard_integrations", "Connection test failed: %{reason}", reason: reason)}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(event, room_data, additional_data) do
    Logger.info("Handling Google Meet event",
      event: event,
      room_id: room_data.room_id,
      additional_data: additional_data
    )

    case event do
      :created ->
        :ok

      :started ->
        :ok

      :ended ->
        :ok

      :cancelled ->
        :ok

      _other ->
        Logger.warning("Unknown Google Meet event", event: event)
        :ok
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      room_id: room_data.room_id,
      meeting_url: room_data.meeting_url,
      provider_name: "Google Meet",
      provider_type: :google_meet,
      supports_dial_in: true,
      supports_recording: true,
      max_participants: 250,
      meeting_instructions:
        "Click the link to join the Google Meet video conference. You can also dial in using the phone number provided in the meeting details.",
      technical_requirements:
        "Modern web browser or Google Meet mobile app. No additional software required.",
      additional_features: [
        "Recording available",
        "Screen sharing",
        "Live captions",
        "Breakout rooms",
        "Phone dial-in available"
      ]
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  defdelegate build_config(integration, decrypted, opts), to: OAuthCredentials

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  defdelegate credential_spec, to: OAuthCredentials

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def url_patterns, do: ["meet.google.com"]

  # Private helper functions (token validation, API calls)
  defp google_oauth_helper do
    Application.get_env(:tymeslot, :google_calendar_oauth_helper, GoogleOAuthHelper)
  end

  defp ensure_valid_token(config) do
    expires_at =
      case config do
        %{token_expires_at: v} -> v
        _other -> nil
      end

    if OAuthTokenManager.token_still_valid?(expires_at) do
      {:ok, config}
    else
      refresh_config(config)
    end
  end

  defp refresh_config(config) do
    OAuthTokenManager.refresh_with_lock(config, %{
      provider: :google_meet,
      refresh: &do_actual_refresh/1,
      already_refreshed: fn config, decrypted ->
        # Another process already refreshed: merge the fresh credentials into
        # the caller's config and return the merged map (Google's return shape).
        {:ok,
         Map.merge(config, %{
           access_token: decrypted.access_token,
           refresh_token: decrypted.refresh_token,
           token_expires_at: decrypted.token_expires_at,
           oauth_scope: decrypted.oauth_scope
         })}
      end
    })
  end

  defp do_actual_refresh(config) do
    refresh_token =
      case config do
        %{refresh_token: v} -> v
        _other -> nil
      end

    current_scope = Map.get(config, :oauth_scope)

    try do
      case google_oauth_helper().refresh_access_token(refresh_token, current_scope) do
        {:ok, new_tokens} ->
          updated_config =
            Map.merge(config, %{
              access_token: new_tokens.access_token,
              refresh_token: new_tokens.refresh_token,
              token_expires_at: new_tokens.expires_at,
              oauth_scope: new_tokens.scope || current_scope
            })

          update_stored_integration(config, updated_config)
          {:ok, updated_config}

        {:error, reason} ->
          {:error, "Failed to refresh token: #{reason}"}
      end
    rescue
      e -> {:error, "Failed to refresh token: #{Exception.message(e)}"}
    end
  end

  # Best-effort persistence: Google does not rotate its refresh token, so the
  # caller can proceed on the merged config even if the write fails. A config
  # carrying no integration ids is transient (a connection probe) and has no
  # row to write back to.
  defp update_stored_integration(old_config, new_config) do
    integration_id = Map.get(old_config, :integration_id)
    user_id = Map.get(old_config, :user_id)

    if is_integer(integration_id) and is_integer(user_id) do
      attrs = %{
        access_token: Map.get(new_config, :access_token),
        refresh_token: Map.get(new_config, :refresh_token),
        token_expires_at: Map.get(new_config, :token_expires_at),
        oauth_scope: Map.get(new_config, :oauth_scope)
      }

      OAuthTokenManager.persist_tokens(old_config, attrs, "Google Meet")
    end

    :ok
  end

  # Creates a standalone Google Meet space via the Meet REST API. An empty body
  # provisions a space with default settings; no calendar event is created.
  defp create_meet_space(config) do
    access_token = Map.get(config, :access_token)

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "https://meet.googleapis.com/v2/spaces"

    case Config.http_client_module().request(:post, url, "{}", headers, []) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, space} -> {:ok, space}
          {:error, _decode_error} -> {:error, "Invalid JSON response from Google Meet API"}
        end

      {:ok, %Req.Response{status: 401, body: body}} ->
        Logger.error("Google Meet API rejected the access token",
          status: 401,
          body: Redactor.redact_and_truncate(body)
        )

        # The access token was rejected even though it had survived token
        # validation/refresh — this indicates server-side revocation or consent
        # withdrawal at Google. Flag the integration so the dashboard shows the
        # "Reconnect required" badge immediately. Mirrors Zoom's flag_revoked_token/1.
        flag_revoked_token(config)
        {:error, "Google Meet API error: HTTP 401 (see logs for details)"}

      {:ok, %Req.Response{status: 403, body: body}} ->
        Logger.error(
          "Google Meet API denied access — the Google Meet API may be disabled for the " <>
            "Cloud project (enable it in the Google Cloud console)",
          status: 403,
          body: Redactor.redact_and_truncate(body)
        )

        {:error, "Google Meet API error: HTTP 403 (Meet API may be disabled; see logs)"}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Google Meet API error creating space",
          status: status,
          body: Redactor.redact_and_truncate(body)
        )

        {:error, "Google Meet API error: HTTP #{status} (see logs for details)"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  # Ends the active conference on a space when a meeting is cancelled. The space
  # itself is not a calendar event and cannot be deleted via the API, but ending
  # any in-progress call is the closest equivalent to "tearing down the room".
  #
  # Best-effort by design: cancellation must never fail because of Meet cleanup.
  # The common case — no one is in the call — returns 400 FAILED_PRECONDITION,
  # which we treat as success. Legacy meetings stored a meeting *code* rather
  # than a space id, which yields 403/404 here; those are also treated as no-ops.
  defp end_active_conference(config, space_id) do
    access_token = Map.get(config, :access_token)

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "https://meet.googleapis.com/v2/spaces/#{space_id}:endActiveConference"

    case Config.http_client_module().request(:post, url, "{}", headers, []) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} when status in [400, 403, 404] ->
        # 400: no active conference. 403/404: space not addressable (e.g. a
        # legacy meeting-code id) or already gone. Nothing to tear down.
        Logger.debug("No active Google Meet conference to end; treating as success",
          room_id: space_id,
          status: status
        )

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Google Meet endActiveConference failed",
          room_id: space_id,
          status: status,
          body: Redactor.redact_and_truncate(body)
        )

        {:error, "Google Meet API error: HTTP #{status} (see logs for details)"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  # Flags the integration as needing reauthentication after a 401 from Google —
  # i.e. the credentials are no longer accepted server-side. The dashboard
  # surfaces this via the "Reconnect required" badge on the video row. Purely
  # additive: it does not touch token validation or the OAuthTokenManager flow.
  defp flag_revoked_token(config) do
    OAuthTokenManager.flag_needs_reauth(config,
      label: "Google Meet",
      event: "google_meet_token_revoked",
      message:
        dgettext(
          "dashboard_integrations",
          "Google Meet access was revoked. Please reconnect your Google account."
        )
    )
  end

  defp get_calendar_list(config) do
    access_token = Map.get(config, :access_token)

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "https://www.googleapis.com/calendar/v3/users/me/calendarList"

    case Config.http_client_module().request(:get, url, "", headers, []) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, list} ->
            {:ok, list}

          {:error, _decode_error} ->
            {:error,
             dgettext("dashboard_integrations", "Invalid JSON response from Google Calendar API")}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Google Calendar API error fetching calendar list",
          status: status,
          body: Redactor.redact_and_truncate(body)
        )

        {:error,
         dgettext("dashboard_integrations", "HTTP %{status} (see logs for details)",
           status: status
         )}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Extracts the room data we persist from a Meet space response. We store the
  # space *id* (the segment after `spaces/`) as the room_id, because that is the
  # identifier `endActiveConference` requires on cancellation — the meeting code
  # is not accepted there. The human-facing join link lives in `meeting_url`.
  defp extract_space_data(space) do
    meeting_url = space["meetingUri"]
    space_id = space_id_from_name(space["name"])

    cond do
      not (is_binary(meeting_url) and meeting_url != "") ->
        {:error, "Google Meet did not return a meeting URL"}

      is_nil(space_id) ->
        {:error, "Google Meet did not return a space identifier"}

      true ->
        {:ok, %RoomData{room_id: space_id, meeting_url: meeting_url, provider_data: space}}
    end
  end

  defp space_id_from_name("spaces/" <> id) when id != "", do: id
  defp space_id_from_name(_other), do: nil
end
