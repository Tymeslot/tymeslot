defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProvider do
  @moduledoc """
  Google Meet video conferencing provider implementation.

  This provider creates Google Meet links by creating calendar events
  with Google Meet conferencing data via the Google Calendar API.
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :google_meet

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Google Meet"

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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
    _other -> nil
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
    _other -> false
  end

  def valid_meeting_url?(_url), do: false

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

      _other ->
        Logger.warning("Unknown Google Meet event", event: event)
        :ok
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def build_config(integration, decrypted, _opts) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def credential_spec do
    %{
      required: [],
      credential_pairs: [
        {:access_token, :access_token_encrypted},
        {:refresh_token, :refresh_token_encrypted}
      ],
      url_fields: []
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def url_patterns, do: ["meet.google.com"]

  # Private helper functions (token validation, API calls)
  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end

  defp google_oauth_helper do
    Application.get_env(:tymeslot, :google_calendar_oauth_helper, GoogleOAuthHelper)
  end

  defp ensure_valid_token(config) do
    expires_at =
      case config do
        %{token_expires_at: v} -> v
        _other -> nil
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
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      # Fallback if we don't have enough info to lock/re-fetch
      do_actual_refresh(config)
    else
      Lock.with_lock(
        {:google_meet, integration_id},
        fn ->
          # Re-fetch from DB to see if another process refreshed it while we waited
          case Video.fetch_integration_for_user(integration_id, user_id) do
            {:ok, fresh_integration} ->
              decrypted = VideoIntegrationSchema.decrypt_credentials(fresh_integration)

              if expiring_later_than_buffer?(decrypted.token_expires_at) do
                # Already refreshed by someone else
                {:ok,
                 Map.merge(config, %{
                   access_token: decrypted.access_token,
                   refresh_token: decrypted.refresh_token,
                   token_expires_at: decrypted.token_expires_at,
                   oauth_scope: fresh_integration.oauth_scope
                 })}
              else
                do_actual_refresh(config)
              end

            {:error, :not_found} ->
              do_actual_refresh(config)
          end
        end,
        mode: :blocking
      )
    end
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

  defp update_stored_integration(old_config, new_config) do
    integration_id = Map.get(old_config, :integration_id)
    user_id = Map.get(old_config, :user_id)

    attrs = %{
      access_token: Map.get(new_config, :access_token),
      refresh_token: Map.get(new_config, :refresh_token),
      token_expires_at: Map.get(new_config, :token_expires_at),
      oauth_scope: Map.get(new_config, :oauth_scope)
    }

    with id when is_integer(id) <- integration_id,
         uid when is_integer(uid) <- user_id,
         {:ok, integration} <- Video.fetch_integration_for_user(id, uid),
         {:ok, _result} <- VideoIntegrationQueries.update(integration, attrs) do
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
    event_details = Map.get(config, :event_details) || %{}

    {start_time, end_time} = resolve_event_times(event_details)

    event_data = %{
      summary: resolve_event_summary(event_details),
      description: resolve_event_description(event_details),
      start: %{dateTime: DateTime.to_iso8601(start_time), timeZone: "UTC"},
      end: %{dateTime: DateTime.to_iso8601(end_time), timeZone: "UTC"},
      conferenceData: %{
        createRequest: %{
          requestId: generate_request_id(),
          conferenceSolutionKey: %{type: "hangoutsMeet"}
        }
      },
      attendees: resolve_event_attendees(event_details),
      reminders: %{useDefault: false, overrides: []}
    }

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    url =
      "https://www.googleapis.com/calendar/v3/calendars/#{calendar_id}/events?conferenceDataVersion=1"

    body = Jason.encode!(event_data)

    case http_client().request(:post, url, body, headers, []) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, event} -> {:ok, event}
          {:error, _decode_error} -> {:error, "Invalid JSON response from Google Calendar API"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Google Calendar API error in Google Meet provider",
          status: status,
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

    case http_client().request(:get, url, "", headers, []) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, list} -> {:ok, list}
          {:error, _decode_error} -> {:error, "Invalid JSON response from Google Calendar API"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Google Calendar API error fetching calendar list",
          status: status,
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

      _other ->
        {:error, "Google Calendar did not return conference data"}
    end
  end

  defp generate_request_id do
    Base.encode16(:crypto.strong_rand_bytes(8))
  end

  defp resolve_event_summary(event_details) do
    case Map.get(event_details, :summary) do
      summary when is_binary(summary) and summary != "" -> summary
      _other -> "Tymeslot - Temporary Event for Google Meet"
    end
  end

  defp resolve_event_description(event_details) do
    case Map.get(event_details, :description) do
      description when is_binary(description) and description != "" -> description
      _other -> ""
    end
  end

  defp resolve_event_times(event_details) do
    start_time = Map.get(event_details, :start_time)
    end_time = Map.get(event_details, :end_time)

    if is_struct(start_time, DateTime) and is_struct(end_time, DateTime) do
      {start_time, end_time}
    else
      now = DateTime.utc_now()
      fallback_start = DateTime.add(now, 3600, :second)
      fallback_end = DateTime.add(fallback_start, 1800, :second)
      {fallback_start, fallback_end}
    end
  end

  defp resolve_event_attendees(event_details) do
    case Map.get(event_details, :attendees) do
      attendees when is_list(attendees) ->
        attendees
        |> Enum.map(&normalise_attendee/1)
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp normalise_attendee(%{email: email}) when is_binary(email) and email != "",
    do: %{email: email}

  defp normalise_attendee(%{"email" => email}) when is_binary(email) and email != "",
    do: %{email: email}

  defp normalise_attendee(email) when is_binary(email) and email != "", do: %{email: email}
  defp normalise_attendee(_other), do: nil
end
