defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider do
  @moduledoc """
  Microsoft Teams video conferencing provider implementation.

  Uses Microsoft Graph API to create scheduled Teams meetings with OAuth 2.0 delegated authentication.
  Provides seamless OAuth integration allowing users to create Teams meetings on their behalf.
  """

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @graph_api_base_url "https://graph.microsoft.com/v1.0"
  @teams_url_pattern ~r/teams\.microsoft\.com\/l\/meetup-join\//

  @impl true
  def create_meeting_room(config) do
    Logger.info("Creating Microsoft Teams meeting room")

    with {:ok, token} <- get_access_token(config),
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

  @impl true
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

  @impl true
  def extract_room_id(meeting_url) do
    case Regex.run(~r/meetup-join\/([^\/\?]+)/, meeting_url) do
      [_, encoded_id] -> String.slice(encoded_id, 0, 20)
      _ -> nil
    end
  end

  @impl true
  def valid_meeting_url?(meeting_url) do
    meeting_url =~ @teams_url_pattern
  end

  @impl true
  def test_connection(config) do
    case get_access_token(config) do
      {:ok, _token} ->
        {:ok, "Successfully authenticated with Microsoft Teams"}

      {:error, reason} ->
        {:error, "Failed to authenticate with Microsoft Teams: #{inspect(reason)}"}
    end
  end

  @impl true
  def provider_type, do: :teams

  @impl true
  def display_name, do: "Microsoft Teams"

  @impl true
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

  @impl true
  def validate_config(config) do
    ProviderConfigHelper.validate_required_fields(config, [
      :access_token,
      :refresh_token,
      :token_expires_at
    ])
  end

  @impl true
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

  @impl true
  def handle_meeting_event(:meeting_ended, room_data, _additional_data) do
    Logger.info("Teams meeting ended: #{room_data.room_id}")
    :ok
  end

  def handle_meeting_event(_event, _room_data, _additional_data) do
    :ok
  end

  @impl true
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

  defp get_access_token(config) do
    case TeamsOAuthHelper.validate_token(config) do
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
    case TeamsOAuthHelper.refresh_access_token(Map.get(config, :refresh_token)) do
      {:ok, refreshed_tokens} ->
        Logger.info("Successfully refreshed Teams OAuth token")

        if integration_id = Map.get(config, :integration_id) do
          update_integration_tokens(integration_id, Map.get(config, :user_id), refreshed_tokens)
        end

        {:ok, refreshed_tokens.access_token}

      {:error, reason} ->
        Logger.error("Failed to refresh Teams OAuth token", reason: inspect(reason))
        {:error, "Token refresh failed: #{reason}"}
    end
  end

  defp update_integration_tokens(integration_id, user_id, refreshed_tokens) do
    attrs = %{
      access_token: refreshed_tokens.access_token,
      refresh_token: refreshed_tokens.refresh_token || refreshed_tokens.access_token,
      token_expires_at: refreshed_tokens.expires_at
    }

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
    start_time =
      Map.get(config, :meeting_start_time) ||
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.to_iso8601()

    end_time =
      Map.get(config, :meeting_end_time) ||
        DateTime.utc_now()
        |> DateTime.add(5400, :second)
        |> DateTime.to_iso8601()

    meeting_data = %{
      startDateTime: start_time,
      endDateTime: end_time,
      subject: Map.get(config, :meeting_topic, "Scheduled Meeting")
    }

    meeting_data =
      if Map.get(config, :enable_lobby, true) do
        Map.put(meeting_data, :lobbyBypassSettings, %{
          scope: "organization",
          isDialInBypassEnabled: false
        })
      else
        meeting_data
      end

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@graph_api_base_url}/me/onlineMeetings"

    case HTTPoison.post(url, Jason.encode!(meeting_data), headers) do
      {:ok, %HTTPoison.Response{status_code: 201, body: body}} ->
        Jason.decode(body)

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp decode_and_format_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        message = error["message"] || "Unknown error"
        code = error["code"] || "Unknown"
        {:error, "Teams API error (#{status}): #{code} - #{message}"}

      _ ->
        {:error, "Failed to create meeting with status #{status}: #{body}"}
    end
  end
end
