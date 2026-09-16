defmodule Tymeslot.Integrations.Video.Providers.KmeetProvider do
  @moduledoc """
  kMeet video conferencing provider.

  kMeet (Infomaniak's Jitsi-based offering) is addressed purely by URL: every
  meeting gets a room on the fixed `kmeet.infomaniak.com` host, keyed off a
  hash of the meeting id, exactly like the custom link provider's template
  mode. There is no API integration and nothing for the user to configure:
  `config_schema/0` is empty and `validate_config/1` accepts anything, and
  `credential_spec/0` declares no required fields.

  Room derivation, URL validation and the reachability probe are shared with
  the custom provider and Jitsi via `Tymeslot.Integrations.Video.Providers.LinkRoom`.
  """

  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.RoomData

  @behaviour ProviderBehaviour

  @host "https://kmeet.infomaniak.com"

  @capabilities Capabilities.new!(
                  waiting_room: false,
                  recording: false,
                  dial_in: false,
                  max_participants: nil,
                  breakout_rooms: false,
                  screen_sharing: true,
                  chat: true
                )

  @impl ProviderBehaviour
  def create_meeting_room(config) do
    with {:ok, %{room_id: room_id, meeting_url: meeting_url}} <-
           LinkRoom.build_room(@host, Map.get(config, :meeting_id)) do
      {:ok,
       %RoomData{
         room_id: room_id,
         meeting_url: meeting_url,
         provider_data: %{host: @host, created_at: DateTime.utc_now()}
       }}
    end
  end

  @impl ProviderBehaviour
  def create_join_url(room_data, _participant_name, _participant_email, _role, _meeting_time),
    do: {:ok, room_data.meeting_url}

  @impl ProviderBehaviour
  def extract_room_id(meeting_url), do: LinkRoom.slug_from_url(meeting_url)

  @impl ProviderBehaviour
  def valid_meeting_url?(meeting_url), do: LinkRoom.http_url?(meeting_url)

  @impl ProviderBehaviour
  def perform_connection_test(_config), do: LinkRoom.connection_test(@host)

  @impl ProviderBehaviour
  def provider_type, do: :kmeet

  @impl ProviderBehaviour
  def display_name, do: "kMeet"

  @impl ProviderBehaviour
  def connection_test_bucket, do: :kmeet

  @impl ProviderBehaviour
  def config_schema, do: %{}

  @impl ProviderBehaviour
  def validate_config(_config), do: :ok

  @impl ProviderBehaviour
  def capabilities, do: @capabilities

  @impl ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "kmeet",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url
    }
  end

  @impl ProviderBehaviour
  def build_config(_integration, _decrypted, opts) do
    %{meeting_id: Keyword.get(opts, :meeting_id)}
  end

  @impl ProviderBehaviour
  def credential_spec do
    %{required: [], credential_pairs: [], url_fields: []}
  end

  @doc """
  The fixed kMeet host, for the connect form's locked field.
  """
  @spec host() :: String.t()
  def host, do: @host
end
