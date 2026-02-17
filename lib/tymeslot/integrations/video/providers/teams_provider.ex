defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider do
  @moduledoc """
  Microsoft Teams video conferencing provider implementation.

  Uses Microsoft Graph API to create scheduled Teams meetings with OAuth 2.0 delegated authentication.
  Provides seamless OAuth integration allowing users to create Teams meetings on their behalf.
  """

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @graph_api_base_url "https://graph.microsoft.com/v1.0"
  @teams_url_pattern ~r/teams\.microsoft\.com\/l\/meetup-join\//

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Microsoft Teams meeting room")

    with {:ok, :valid} <- validate_teams_scope(config),
         {:ok, token} <- get_access_token(config),
         {:ok, meeting} <- create_scheduled_meeting(token, config) do
      room_data = %{
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

      Logger.info("Successfully created Teams meeting with ID: #{room_data.room_id}")
      {:ok, room_data}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create Teams meeting: #{inspect(reason)}")
        error
    end
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

  def extract_room_id(%{room_data: room_data}) do
    room_data[:room_id] || room_data["room_id"]
  end

  def extract_room_id(_other), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(meeting_url) do
    meeting_url =~ @teams_url_pattern
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def test_connection(config) do
    case get_access_token(config) do
      {:ok, _token} ->
        {:ok, "Successfully authenticated with Microsoft Teams"}

      {:error, reason} ->
        {:error, "Failed to authenticate with Microsoft Teams: #{inspect(reason)}"}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :teams

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Microsoft Teams"

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
  def capabilities do
    %{
      supports_instant_meetings: false,
      supports_scheduled_meetings: true,
      supports_recurring_meetings: false,
      supports_waiting_room: true,
      supports_recording: true,
      supports_dial_in: true,
      max_participants: 300,
      requires_account: true,
      supports_custom_branding: false,
      supports_breakout_rooms: true,
      supports_screen_sharing: true,
      supports_chat: true,
      requires_work_account: true
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(:meeting_ended, room_data, _additional_data) do
    Logger.info("Teams meeting ended: #{room_data.room_id}")
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
      passcode: room_data.provider_data["passcode"],
      dial_in_number: room_data.provider_data["toll_number"],
      conference_id: room_data.provider_data["conference_id"]
    }
  end

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

      {:error,
       "Teams integration is missing required permissions. " <>
         "Please disconnect and reconnect your Microsoft Teams integration in the dashboard " <>
         "to grant the necessary permissions for creating meetings."}
    end
  end

  defp get_access_token(config) do
    case teams_oauth_helper().validate_token(config) do
      {:ok, :valid} ->
        {:ok, Map.get(config, :access_token)}

      {:ok, :needs_refresh} ->
        refresh_and_update_token(config)

      {:error, reason} ->
        Logger.error("Token validation failed", reason: inspect(reason))
        {:error, "Token validation failed: #{reason}"}
    end
  end

  defp refresh_and_update_token(config) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      do_actual_refresh(config)
    else
      Lock.with_lock(
        {:teams, integration_id},
        fn -> check_and_refresh_token(integration_id, user_id, config) end,
        mode: :blocking
      )
    end
  end

  defp check_and_refresh_token(integration_id, user_id, config) do
    case VideoIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, fresh_integration} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(fresh_integration)

        if token_still_valid?(decrypted.token_expires_at) do
          {:ok, decrypted.access_token}
        else
          perform_refresh(config)
        end

      _other ->
        perform_refresh(config)
    end
  end

  defp token_still_valid?(expires_at) do
    now = DateTime.utc_now()
    DateTime.compare(expires_at, DateTime.add(now, 300, :second)) == :gt
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

        if integration_id = Map.get(config, :integration_id) do
          update_integration_tokens(integration_id, Map.get(config, :user_id), refreshed_tokens)
        end

        {:ok, refreshed_tokens}

      {:error, reason} ->
        Logger.error("Failed to refresh Teams OAuth token", reason: inspect(reason))
        {:error, "Token refresh failed: #{reason}"}
    end
  end

  defp update_integration_tokens(integration_id, user_id, refreshed_tokens) do
    # Use the scope from refreshed tokens if present, otherwise keep existing scope
    # Microsoft may not return scope in refresh responses, so we preserve what we have
    scope = refreshed_tokens[:scope] || refreshed_tokens.scope

    attrs = %{
      access_token: refreshed_tokens.access_token,
      refresh_token: refreshed_tokens.refresh_token || refreshed_tokens.access_token,
      token_expires_at: refreshed_tokens.expires_at
    }

    # Only update scope if we got a new one from the refresh
    attrs = if scope && scope != "", do: Map.put(attrs, :oauth_scope, scope), else: attrs

    case VideoIntegrationQueries.get_for_user(integration_id, user_id) do
      {:error, :not_found} ->
        Logger.warning(
          "Could not find integration to update tokens for integration ID: #{integration_id}"
        )

      {:ok, integration} ->
        case VideoIntegrationQueries.update(integration, attrs) do
          {:ok, _updated} ->
            Logger.info(
              "Updated Teams OAuth tokens in database for integration ID: #{integration_id}"
            )

          {:error, reason} ->
            Logger.error(
              "Failed to update Teams OAuth tokens in database for integration ID: #{integration_id}",
              reason: inspect(reason)
            )
        end
    end
  end

  defp create_scheduled_meeting(token, config) do
    {start_time, end_time} = get_meeting_times(config)
    meeting_payload = build_meeting_payload(start_time, end_time, config)

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@graph_api_base_url}/me/events"

    case http_client().request(:post, url, Jason.encode!(meeting_payload), headers, []) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        parse_meeting_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
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

  defp parse_meeting_response(body) do
    case Jason.decode(body) do
      {:ok, event} -> extract_join_info(event)
      error -> error
    end
  end

  defp extract_join_info(event) do
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
      {:error,
       "Teams meeting link was not generated for this event. Please ensure your account has Teams enabled."}
    end
  end

  defp personal_account?(config) do
    tenant_id = Map.get(config, :tenant_id)
    # Check if it is the consumer tenant or we don't know yet (common)
    tenant_id == MicrosoftConfig.consumer_tenant_id() or tenant_id == "common" or
      is_nil(tenant_id)
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
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
        {:error, "Failed to create meeting with status #{status}: #{body}"}
    end
  end
end
