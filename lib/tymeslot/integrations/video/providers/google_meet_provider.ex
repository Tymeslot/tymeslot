defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProvider do
  @moduledoc """
  Google Meet video conferencing provider implementation.

  This provider creates Google Meet links by creating calendar events
  with Google Meet conferencing data via the Google Calendar API.
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper

  @impl true
  def provider_type, do: :google_meet

  @impl true
  def display_name, do: "Google Meet"

  @impl true
  def config_schema do
    %{
      access_token: %{type: :string, required: true, description: "Google OAuth access token"},
      refresh_token: %{type: :string, required: true, description: "Google OAuth refresh token"},
      token_expires_at: %{type: :datetime, required: true, description: "Token expiration time"},
      calendar_id: %{
        type: :string,
        required: false,
        description: "Calendar ID for events (defaults to 'primary')"
      }
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
      recording: true,
      screen_sharing: true,
      waiting_room: false,
      max_participants: 250,
      requires_download: false,
      supports_phone_dial_in: true,
      supports_chat: true,
      supports_breakout_rooms: true,
      end_to_end_encryption: true,
      supports_live_streaming: true,
      supports_recording: true
    }
  end

  @impl true
  def create_meeting_room(config) do
    Logger.info("Creating Google Meet room")

    with {:ok, valid_token} <- ensure_valid_token(config),
         {:ok, event_data} <- create_calendar_event_with_meet(valid_token),
         {:ok, room_data} <- extract_meeting_data(event_data) do
      Logger.info("Successfully created Google Meet room", room_id: room_data.room_id)
      {:ok, room_data}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create Google Meet room", reason: Redactor.redact(reason))
        error
    end
  end

  @impl true
  def create_join_url(room_data, participant_name, participant_email, role, _meeting_time) do
    base_url = room_data[:meeting_url] || room_data["meeting_url"]

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
        room_id: room_data[:room_id]
      )

      {:ok, join_url}
    else
      {:error, "Missing meeting URL in room data"}
    end
  end

  @impl true
  def extract_room_id(meeting_url) when is_binary(meeting_url) and meeting_url != "" do
    uri = URI.parse(meeting_url)

    if uri.host == "meet.google.com" and uri.path do
      case String.split(uri.path, "/") do
        [_, meeting_code] when meeting_code != "" -> meeting_code
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  def extract_room_id(_), do: nil

  @impl true
  def valid_meeting_url?(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    uri.host == "meet.google.com" and
      is_binary(uri.path) and
      String.length(uri.path) > 1 and
      String.match?(uri.path, ~r|^/[a-z]{3}-[a-z]{4}-[a-z]{3}$|)
  rescue
    _ -> false
  end

  def valid_meeting_url?(_), do: false

  @impl true
  def test_connection(config) do
    Logger.info("Testing Google Meet connection")

    with {:ok, valid_token} <- ensure_valid_token(config),
         {:ok, _calendar_list} <- get_calendar_list(valid_token) do
      {:ok, "Google Meet connection successful"}
    else
      {:error, reason} ->
        Logger.error("Google Meet connection test failed", reason: Redactor.redact(reason))
        {:error, "Connection test failed: #{reason}"}
    end
  end

  @impl true
  def handle_meeting_event(event, room_data, additional_data) do
    Logger.info("Handling Google Meet event",
      event: event,
      room_id: room_data[:room_id],
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

      _ ->
        Logger.warning("Unknown Google Meet event", event: event)
        :ok
    end
  end

  @impl true
  def generate_meeting_metadata(room_data) do
    room_id = room_data[:room_id] || room_data["room_id"]
    meeting_url = room_data[:meeting_url] || room_data["meeting_url"]

    %{
      room_id: room_id,
      meeting_url: meeting_url,
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

  # Private helper functions (token validation, API calls)
  defp ensure_valid_token(config) do
    expires_at =
      case config do
        %{token_expires_at: v} -> v
        _ -> nil
      end

    if expiring_later_than_buffer?(expires_at) do
      {:ok, config}
    else
      refresh_config(config)
    end
  end

  defp expiring_later_than_buffer?(nil), do: false

  defp expiring_later_than_buffer?(expires_at) do
    buffer_time = DateTime.add(DateTime.utc_now(), 300, :second)
    DateTime.compare(expires_at, buffer_time) == :gt
  end

  defp refresh_config(config) do
    refresh_token =
      case config do
        %{refresh_token: v} -> v
        _ -> nil
      end

    current_scope = Map.get(config, :oauth_scope)

    try do
      case GoogleOAuthHelper.refresh_access_token(refresh_token, current_scope) do
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

  defp update_stored_integration(old_config, new_config) do
    integration_id = Map.get(old_config, :integration_id)
    user_id = Map.get(old_config, :user_id)

    attrs = %{
      access_token: Map.get(new_config, :access_token),
      refresh_token: Map.get(new_config, :refresh_token),
      token_expires_at: Map.get(new_config, :token_expires_at),
      oauth_scope: Map.get(new_config, :oauth_scope)
    }

    with id when not is_nil(id) <- integration_id,
         uid when not is_nil(uid) <- user_id,
         {:ok, integration} <- VideoIntegrationQueries.get_for_user(id, uid),
         {:ok, _} <- VideoIntegrationQueries.update(integration, attrs) do
      :ok
    else
      nil ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "Could not find integration to persist refreshed Google tokens",
          integration_id: integration_id,
          user_id: user_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to persist refreshed Google tokens", reason: Redactor.redact(reason))
        :ok
    end
  end

  defp create_calendar_event_with_meet(config) do
    calendar_id = Map.get(config, :calendar_id, "primary")
    access_token = Map.get(config, :access_token)

    now = DateTime.utc_now()
    start_time = DateTime.add(now, 3600, :second)
    end_time = DateTime.add(start_time, 1800, :second)

    event_data = %{
      summary: "Tymeslot - Temporary Event for Google Meet",
      description: "Temporary event created by Tymeslot to generate a Google Meet link.",
      start: %{dateTime: DateTime.to_iso8601(start_time), timeZone: "UTC"},
      end: %{dateTime: DateTime.to_iso8601(end_time), timeZone: "UTC"},
      conferenceData: %{
        createRequest: %{
          requestId: generate_request_id(),
          conferenceSolutionKey: %{type: "hangoutsMeet"}
        }
      },
      attendees: [],
      reminders: %{useDefault: false, overrides: []}
    }

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url =
      "https://www.googleapis.com/calendar/v3/calendars/#{calendar_id}/events?conferenceDataVersion=1"

    body = Jason.encode!(event_data)

    case HTTPClient.request(:post, url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        event = Jason.decode!(response_body)
        {:ok, event}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.error("Google Calendar API error in Google Meet provider",
          status_code: status,
          body: Redactor.redact_and_truncate(body)
        )

        {:error, "Google Calendar API error: HTTP #{status} (see logs for details)"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  defp get_calendar_list(config) do
    access_token = Map.get(config, :access_token)

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "https://www.googleapis.com/calendar/v3/users/me/calendarList"

    case HTTPClient.request(:get, url, "", headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        list = Jason.decode!(response_body)
        {:ok, list}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.error("Google Calendar API error fetching calendar list",
          status_code: status,
          body: Redactor.redact_and_truncate(body)
        )

        {:error, "HTTP #{status} (see logs for details)"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp extract_meeting_data(event) do
    case get_in(event, ["conferenceData", "entryPoints"]) do
      entry_points when is_list(entry_points) ->
        found_ep = Enum.find(entry_points, fn ep -> ep["entryPointType"] == "video" end)

        meeting_url =
          case found_ep do
            nil -> nil
            ep -> ep["uri"]
          end

        room_id = extract_room_id(meeting_url)

        if meeting_url do
          {:ok, %{room_id: room_id, meeting_url: meeting_url, provider_data: event}}
        else
          {:error, "No meeting URL returned from Google"}
        end

      _ ->
        {:error, "Google Calendar did not return conference data"}
    end
  end

  defp generate_request_id do
    Base.encode16(:crypto.strong_rand_bytes(8))
  end
end
