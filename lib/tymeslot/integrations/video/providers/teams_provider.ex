defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider do
  @moduledoc """
  Microsoft Teams video conferencing provider implementation.

  Uses Microsoft Graph API to create scheduled Teams meetings with OAuth 2.0 delegated authentication.
  Provides seamless OAuth integration allowing users to create Teams meetings on their behalf.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @capabilities Capabilities.new!(
                  waiting_room: true,
                  recording: true,
                  dial_in: true,
                  max_participants: 300,
                  breakout_rooms: true,
                  screen_sharing: true,
                  chat: true
                )

  @graph_api_base_url "https://graph.microsoft.com/v1.0"
  @teams_url_pattern ~r/teams\.microsoft\.com\/l\/meetup-join\//

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Microsoft Teams meeting room")

    case precheck_create_meeting_room(config) do
      {:ok, token} ->
        finish_create_meeting_room(token, config)

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
  # comment on `ProviderAdapter.with_breaker/2`). Runs before the shared Teams
  # breaker is ever asked for permission.
  #
  # Scope validation is pure, no network at all, so it can never represent
  # Teams/Graph being down. Token acquisition *is* network I/O, but against
  # Microsoft's OAuth host rather than Graph's meetings API, and its failures
  # are classified before they reach the breaker: a rejected/expired grant is
  # the tenant's problem (`{:error, _}`, bypasses the breaker entirely), while
  # anything else — a timeout or 5xx from the OAuth host — comes back as
  # `{:provider_error, _}` so the caller can still let the breaker witness it.
  @spec precheck_create_meeting_room(map()) ::
          {:ok, String.t()} | {:error, term()} | {:provider_error, term()}
  def precheck_create_meeting_room(config) do
    with {:ok, :valid} <- validate_teams_scope(config) do
      classify_token_result(get_access_token(config))
    end
  end

  @doc false
  # The actual outbound Graph API call, meant to run behind the shared
  # breaker. Takes the token `precheck_create_meeting_room/1` already
  # resolved, so it never repeats the OAuth round-trip.
  @spec finish_create_meeting_room(String.t(), map()) ::
          {:ok, RoomData.t()} | {:error, term()}
  def finish_create_meeting_room(token, config) do
    case create_scheduled_meeting(token, config) do
      {:ok, meeting} ->
        room_data = %RoomData{
          room_id: meeting["id"],
          meeting_url: meeting["joinUrl"],
          provider_data: %{
            join_web_url: meeting["joinWebUrl"],
            video_teleconference_id: meeting["videoTeleconferenceId"],
            passcode: meeting["passcode"],
            toll_number: get_in(meeting, ["audioConferencing", "tollNumber"]),
            conference_id: get_in(meeting, ["audioConferencing", "conferenceId"])
          }
        }

        Logger.info("Successfully created Teams meeting", room_id: room_data.room_id)
        {:ok, room_data}

      {:error, reason} = error ->
        log_create_meeting_room_error(reason)
        error
    end
  end

  defp log_create_meeting_room_error(reason) do
    Logger.error("Failed to create Teams meeting", error: inspect(reason))
  end

  # A rejected/expired grant (`invalid_grant`, `invalid_client`,
  # `access_denied`) is the tenant's credential, not Graph's availability —
  # `BreakerOutcome.permanent_credential_error?/1` shares this rule with
  # `HealthCheck.ResponseHandler`'s reauth fast-path (both Teams and Zoom
  # refresh through the shared `ErrorParser.build_message/3`). Anything else
  # (network error, an unrecognised HTTP status) is handed back for the
  # breaker to witness.
  defp classify_token_result({:ok, _token} = ok), do: ok

  defp classify_token_result({:error, reason} = error) do
    if BreakerOutcome.permanent_credential_error?(reason),
      do: error,
      else: {:provider_error, reason}
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, _participant_email, _role, _meeting_time) do
    base_url = room_data.meeting_url

    url =
      if String.contains?(base_url, "?") do
        "#{base_url}&displayName=#{URI.encode(participant_name)}"
      else
        "#{base_url}?displayName=#{URI.encode(participant_name)}"
      end

    {:ok, url}
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    case Regex.run(~r/meetup-join\/([^\/\?]+)/, meeting_url) do
      [_first, encoded_id] -> String.slice(encoded_id, 0, 20)
      _other -> meeting_url
    end
  end

  def extract_room_id(_other), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(meeting_url) do
    meeting_url =~ @teams_url_pattern
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    case get_access_token(config) do
      {:ok, _token} ->
        {:ok, dgettext("dashboard_integrations", "Microsoft Teams connected successfully!")}

      {:error, reason} ->
        {:error,
         dgettext(
           "dashboard_integrations",
           "Failed to authenticate with Microsoft Teams: %{reason}",
           reason: inspect(reason)
         )}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :teams

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Microsoft Teams"

  # A per-actor bucket shared across every OAuth-backed provider: the test
  # itself rides on a token that is already scarce, but without a charge
  # here it is unbounded and can burn the instance-wide OAuth quota shared
  # by every user.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def connection_test_bucket, do: :oauth

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def config_schema do
    %{
      access_token: %{type: :string, required: true, description: "Microsoft OAuth access token"},
      refresh_token: %{
        type: :string,
        required: true,
        description: "Microsoft OAuth refresh token"
      },
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
  def handle_meeting_event(:meeting_ended, room_data, _additional_data) do
    Logger.info("Teams meeting ended", room_id: room_data.room_id)
    :ok
  end

  def handle_meeting_event(_other_event, _room_data, _additional_data) do
    :ok
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "teams",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url,
      passcode: room_data.provider_data[:passcode],
      dial_in_number: room_data.provider_data[:toll_number],
      conference_id: room_data.provider_data[:conference_id]
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def build_config(integration, decrypted, _opts) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      tenant_id: decrypted.tenant_id,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def credential_spec do
    %{
      required: [],
      credential_pairs: [
        {:tenant_id, :tenant_id_encrypted},
        {:teams_user_id, :teams_user_id_encrypted}
      ],
      url_fields: []
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def url_patterns, do: ["teams.microsoft.com"]

  # Private functions

  defp validate_teams_scope(config) do
    stored_scope = Map.get(config, :oauth_scope) || ""
    # Calendars.ReadWrite is a valid scope for creating Teams meetings via calendar events
    required_scopes = ["Calendars.ReadWrite"]
    downcased_scope = String.downcase(stored_scope)

    has_required_scope =
      Enum.any?(required_scopes, fn scope ->
        String.contains?(downcased_scope, String.downcase(scope))
      end)

    if has_required_scope do
      {:ok, :valid}
    else
      Logger.error(
        "Teams integration missing required scope. Stored scope: #{stored_scope}. " <>
          "Required one of: #{inspect(required_scopes)}. User needs to re-authenticate."
      )

      # Tagged, not prose, for the same reason as `:video_meeting_not_enabled`:
      # the consent the integration was granted only changes when the user
      # reconnects it, so retrying this job cannot help, and the caller's error
      # policy has to be able to see that. The user is told to reconnect through
      # the dashboard's integration health badge, not through this reason.
      {:error, :invalid_configuration}
    end
  end

  defp get_access_token(config) do
    OAuthTokenManager.validated_access_token(config,
      oauth_helper: teams_oauth_helper(),
      label: "Teams",
      on_refresh: &refresh_and_update_token/1
    )
  end

  defp refresh_and_update_token(config) do
    OAuthTokenManager.refresh_with_lock(config, %{
      provider: :teams,
      refresh: &perform_refresh/1,
      already_refreshed: fn _config, decrypted -> {:ok, decrypted.access_token} end,
      fallback_refresh: &perform_refresh/1
    })
  end

  defp perform_refresh(config) do
    case do_actual_refresh(config) do
      {:ok, refreshed_tokens} -> {:ok, refreshed_tokens.access_token}
      error -> error
    end
  end

  defp do_actual_refresh(config) do
    refresh_token = Map.get(config, :refresh_token)
    # Always use Teams-specific scope when refreshing, not the stored scope
    # The stored scope might be from calendar integration and won't work for Teams meetings
    # Pass nil to use default Teams scope from TeamsOAuthHelper
    teams_scope = nil

    case teams_oauth_helper().refresh_access_token(refresh_token, teams_scope) do
      {:ok, refreshed_tokens} ->
        Logger.info("Successfully refreshed Teams OAuth token")

        # Best-effort persistence: Teams does not rotate its refresh token, so a
        # failed write leaves the stored credentials still usable and the caller
        # can proceed with the token it just obtained.
        if Map.get(config, :integration_id) do
          OAuthTokenManager.persist_tokens(config, token_attrs(refreshed_tokens), "Teams")
        end

        {:ok, refreshed_tokens}

      {:error, reason} ->
        Logger.error("Failed to refresh Teams OAuth token", reason: inspect(reason))
        {:error, "Token refresh failed: #{reason}"}
    end
  end

  # Microsoft may omit the scope from a refresh response, so an absent or blank
  # one leaves the stored scope alone rather than clearing it.
  defp token_attrs(refreshed_tokens) do
    attrs = %{
      access_token: refreshed_tokens.access_token,
      refresh_token: refreshed_tokens.refresh_token || refreshed_tokens.access_token,
      token_expires_at: refreshed_tokens.expires_at
    }

    maybe_put_scope(attrs, refreshed_tokens[:scope] || refreshed_tokens.scope)
  end

  defp maybe_put_scope(attrs, scope) when is_binary(scope) and scope != "",
    do: Map.put(attrs, :oauth_scope, scope)

  defp maybe_put_scope(attrs, _scope), do: attrs

  defp create_scheduled_meeting(token, config) do
    {start_time, end_time} = get_meeting_times(config)
    meeting_payload = build_meeting_payload(start_time, end_time, config)

    headers = graph_headers(token)

    url = "#{@graph_api_base_url}/me/events"

    case Config.http_client_module().request(
           :post,
           url,
           Jason.encode!(meeting_payload),
           headers,
           []
         ) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        parse_meeting_response(token, body)

      {:ok, %Req.Response{status: 401, body: body}} ->
        # The access token was rejected by Graph even though it had survived
        # token validation/refresh — this indicates server-side revocation or a
        # consent withdrawal. Flag the integration so the dashboard surfaces the
        # "Reconnect required" badge immediately, rather than waiting for the
        # async HealthCheck cycle. Mirrors Zoom's flag_revoked_token/1.
        flag_revoked_token(config)
        decode_and_format_error(401, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  # Flags the integration as needing reauthentication after a 401 from Graph —
  # i.e. the credentials are no longer accepted server-side. The dashboard
  # surfaces this via the "Reconnect required" badge on the video row. Purely
  # additive: it does not touch token validation or the OAuthTokenManager flow.
  defp flag_revoked_token(config) do
    OAuthTokenManager.flag_needs_reauth(config,
      label: "Teams",
      event: "teams_token_revoked",
      message:
        dgettext(
          "dashboard_integrations",
          "Microsoft Teams access was revoked. Please reconnect your Teams account."
        )
    )
  end

  defp get_meeting_times(config) do
    start_time =
      case Map.get(config, :meeting_start_time) do
        nil -> DateTime.add(DateTime.utc_now(), 3600, :second)
        dt when is_binary(dt) -> parse_iso8601!(dt)
        dt -> dt
      end

    end_time =
      case Map.get(config, :meeting_end_time) do
        nil -> DateTime.add(start_time, 1800, :second)
        dt when is_binary(dt) -> parse_iso8601!(dt)
        dt -> dt
      end

    {start_time, end_time}
  end

  defp parse_iso8601!(dt) do
    {:ok, parsed, _offset} = DateTime.from_iso8601(dt)
    parsed
  end

  defp build_meeting_payload(start_time, end_time, config) do
    payload = %{
      subject: Map.get(config, :meeting_topic, "Scheduled Meeting"),
      start: %{dateTime: DateTime.to_iso8601(start_time), timeZone: "UTC"},
      end: %{dateTime: DateTime.to_iso8601(end_time), timeZone: "UTC"},
      isOnlineMeeting: true
    }

    if personal_account?(config) do
      payload
    else
      Map.put(payload, :onlineMeetingProvider, "teamsForBusiness")
    end
  end

  defp parse_meeting_response(token, body) do
    case Jason.decode(body) do
      {:ok, event} -> extract_join_info(token, event)
      error -> error
    end
  end

  defp extract_join_info(token, event) do
    join_url = get_in(event, ["onlineMeeting", "joinUrl"]) || event["onlineMeetingUrl"]

    if join_url do
      {:ok,
       %{
         "id" => event["id"],
         "joinUrl" => join_url,
         "joinWebUrl" => join_url,
         "videoTeleconferenceId" => nil,
         "passcode" => nil
       }}
    else
      # Graph answered 201, so the calendar event exists on the account even
      # though it carries no Teams link — the account cannot host Teams
      # meetings. Left behind, every attempt would deposit another placeholder
      # in the organiser's calendar, so the event is removed before the failure
      # is reported. A tagged reason rather than a sentence: the caller's error
      # policy has to recognise this as terminal, and it cannot match on prose.
      delete_orphaned_event(token, event["id"])
      {:error, :video_meeting_not_enabled}
    end
  end

  # Best-effort: the room creation has already failed and the caller's outcome
  # does not change either way, so a failed cleanup is logged, never raised.
  defp delete_orphaned_event(_token, nil), do: :ok

  defp delete_orphaned_event(token, event_id) do
    url = "#{@graph_api_base_url}/me/events/#{URI.encode(event_id)}"

    case Config.http_client_module().request(:delete, url, "", graph_headers(token), []) do
      {:ok, %Req.Response{status: status}} when status in [200, 202, 204] ->
        Logger.info("Deleted Teams calendar event left without a join link")
        :ok

      other ->
        Logger.warning("Could not delete Teams calendar event left without a join link",
          result: inspect(other)
        )

        :ok
    end
  end

  defp graph_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp personal_account?(config) do
    tenant_id = Map.get(config, :tenant_id)
    # Check if it is the consumer tenant or we don't know yet (common)
    tenant_id == MicrosoftConfig.consumer_tenant_id() or tenant_id == "common" or
      is_nil(tenant_id)
  end

  defp teams_oauth_helper do
    Application.get_env(:tymeslot, :teams_oauth_helper, TeamsOAuthHelper)
  end

  defp decode_and_format_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        message = error["message"] || "Unknown error"
        code = error["code"] || "Unknown"

        # Check if this is an authentication error that might be due to missing scopes
        error_message =
          if code == "AuthenticationError" do
            "Teams API error (#{status}): #{code} - #{message}. " <>
              "This usually means the integration needs to be re-authenticated with Teams-specific permissions. " <>
              "Please disconnect and reconnect your Microsoft Teams integration in the dashboard."
          else
            "Teams API error (#{status}): #{code} - #{message}"
          end

        {:error, error_message}

      _other ->
        # Undecodable body: still bounded and scrubbed before it reaches a log
        # line, so a provider that answers with something unexpected cannot
        # write an unbounded blob (or whatever it happens to contain) to disk.
        {:error,
         "Failed to create meeting with status #{status}: " <>
           Redactor.redact_and_truncate(body)}
    end
  end
end
