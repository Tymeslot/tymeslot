defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider do
  @moduledoc """
  Zoom video conferencing provider.

  Uses the Zoom REST API v2 with OAuth 2.0 user-managed authentication
  to create scheduled Zoom meetings on the connected user's account.
  Zoom is not a calendar provider — the join URL is embedded into
  calendar events created by the user's calendar provider.
  """

  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger

  @behaviour ProviderBehaviour

  @zoom_url_pattern ~r/zoom\.us\/(j|my|w)\//

  @impl ProviderBehaviour
  def create_meeting_room(_config) do
    {:error, "Zoom meeting creation not yet implemented"}
  end

  @impl ProviderBehaviour
  def create_join_url(room_data, participant_name, _participant_email, _role, _meeting_time) do
    case room_data.meeting_url do
      nil ->
        {:error, "Missing meeting URL in room data"}

      base_url ->
        url =
          if String.contains?(base_url, "?") do
            "#{base_url}&uname=#{URI.encode(participant_name)}"
          else
            "#{base_url}?uname=#{URI.encode(participant_name)}"
          end

        {:ok, url}
    end
  end

  @impl ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    case Regex.run(~r/zoom\.us\/(?:j|my|w)\/(\d+)/, meeting_url) do
      [_full, id] -> id
      _no_match -> nil
    end
  end

  def extract_room_id(%{room_data: room_data}) do
    room_data[:room_id] || room_data["room_id"]
  end

  def extract_room_id(_other), do: nil

  @impl ProviderBehaviour
  def valid_meeting_url?(meeting_url), do: meeting_url =~ @zoom_url_pattern

  @impl ProviderBehaviour
  def test_connection(_config) do
    {:error, "Zoom connection test not yet implemented"}
  end

  @impl ProviderBehaviour
  def provider_type, do: :zoom

  @impl ProviderBehaviour
  def display_name, do: "Zoom"

  @impl ProviderBehaviour
  def config_schema do
    %{
      access_token: %{type: :string, required: true, description: "Zoom OAuth access token"},
      refresh_token: %{type: :string, required: true, description: "Zoom OAuth refresh token"},
      token_expires_at: %{type: :datetime, required: true, description: "Token expiration time"}
    }
  end

  @impl ProviderBehaviour
  def validate_config(config) do
    ProviderConfigHelper.validate_required_fields(config, [
      :access_token,
      :refresh_token,
      :token_expires_at
    ])
  end

  @impl ProviderBehaviour
  def capabilities do
    %{
      supports_instant_meetings: true,
      supports_scheduled_meetings: true,
      supports_recurring_meetings: true,
      supports_waiting_room: true,
      supports_recording: true,
      supports_dial_in: true,
      max_participants: 100,
      requires_account: true,
      supports_custom_branding: false,
      supports_breakout_rooms: true,
      supports_screen_sharing: true,
      supports_chat: true,
      requires_work_account: false
    }
  end

  @impl ProviderBehaviour
  def handle_meeting_event(:meeting_ended, room_data, _additional_data) do
    Logger.info("Zoom meeting ended", room_id: room_data.room_id)
    :ok
  end

  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "zoom",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url,
      passcode: room_data.provider_data[:passcode] || room_data.provider_data["passcode"],
      host_url: room_data.provider_data[:start_url] || room_data.provider_data["start_url"]
    }
  end
end
