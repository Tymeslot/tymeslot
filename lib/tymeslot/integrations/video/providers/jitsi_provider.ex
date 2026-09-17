defmodule Tymeslot.Integrations.Video.Providers.JitsiProvider do
  @moduledoc """
  Self-hosted Jitsi Meet video conferencing provider.

  Every meeting gets a room on the user's own Jitsi server, keyed off a hash
  of the meeting id, exactly like kMeet but on a configurable `base_url`.
  Room derivation, URL validation and the reachability probe are shared via
  `Tymeslot.Integrations.Video.Providers.LinkRoom`.

  ## Optional token authentication

  A server configured for JWT authentication admits only visitors holding a
  token signed with its shared secret. When the integration carries an App ID
  (`client_id`) and an App secret (`client_secret`), every join URL gets its
  own token from `Tymeslot.Integrations.Video.Providers.Jitsi.Token`, scoped
  to the meeting's room and valid until a grace period after the meeting
  starts. Without credentials the bare room URL is handed out, which suits an
  open server.

  The token expires four hours after the meeting's start, so a participant
  reconnecting later than that in a very long meeting is refused.

  Should minting ever fail, the bare room URL is handed out instead and the
  failure is logged (room id and reason only). A room link that may ask for
  a login is strictly better than no usable link at all.

  The organiser's token flags them as a moderator and the attendee's does
  not. That flag grants nothing by itself: it takes effect only on a server
  configured to honour it.

  The credentials are optional, but all or nothing: `validate_config/1`
  refuses half a pair, and a secret shorter than 32 bytes, since every guest
  receives a token signed with it. A credential that is only whitespace counts
  as absent, and surrounding whitespace is trimmed before either is used.

  The credentials never enter `RoomData.provider_data`. `create_join_url/5`
  reads them from `RoomData.provider_config`, the in-memory config the room
  was created from, which is never persisted, logged or sent to a client.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.Jitsi.Token
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.RoomData

  @behaviour ProviderBehaviour

  # A token has to outlive the meeting itself: it is minted when the booking is
  # confirmed and used when the meeting starts, which may be months later.
  @token_grace_seconds 4 * 60 * 60

  # HS256 is only as strong as its key, and the key signs a token that every
  # guest receives, so it is open to offline guessing from any booking link.
  @min_secret_bytes 32

  @organizer_role "organizer"

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
    with {:ok, base_url} <- fetch_base_url(config),
         {:ok, %{room_id: room_id, meeting_url: meeting_url}} <-
           LinkRoom.build_room(base_url, Map.get(config, :meeting_id)) do
      {:ok,
       %RoomData{
         room_id: room_id,
         meeting_url: meeting_url,
         provider_data: %{base_url: base_url, created_at: DateTime.utc_now()},
         provider_config: config
       }}
    end
  end

  @impl ProviderBehaviour
  def create_join_url(room_data, participant_name, participant_email, role, meeting_time) do
    case credentials(room_data.provider_config) do
      nil ->
        {:ok, room_data.meeting_url}

      {app_id, secret} ->
        mint_join_url(room_data, app_id, secret,
          name: participant_name,
          email: participant_email,
          moderator: role == @organizer_role,
          expires_at: expiry(meeting_time)
        )
    end
  end

  @impl ProviderBehaviour
  def extract_room_id(meeting_url), do: LinkRoom.slug_from_url(meeting_url)

  @impl ProviderBehaviour
  def valid_meeting_url?(meeting_url), do: LinkRoom.room_url?(meeting_url)

  @impl ProviderBehaviour
  def perform_connection_test(config) do
    with {:ok, base_url} <- fetch_base_url(config) do
      LinkRoom.connection_test(base_url)
    end
  end

  @impl ProviderBehaviour
  def provider_type, do: :jitsi

  @impl ProviderBehaviour
  def display_name, do: "Jitsi Meet"

  @impl ProviderBehaviour
  def connection_test_bucket, do: :jitsi

  @impl ProviderBehaviour
  def config_schema do
    %{
      base_url: %{type: :string, required: true, description: "Base URL of the Jitsi server"},
      client_id: %{
        type: :string,
        required: false,
        description: "App ID the Jitsi server expects in its tokens"
      },
      client_secret: %{
        type: :string,
        required: false,
        description: "App secret the Jitsi server verifies its tokens with"
      }
    }
  end

  @impl ProviderBehaviour
  def validate_config(config) do
    with {:ok, _base_url} <- fetch_base_url(config) do
      validate_credentials(present(config[:client_id]), present(config[:client_secret]))
    end
  end

  @impl ProviderBehaviour
  def capabilities, do: @capabilities

  @impl ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "jitsi",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url
    }
  end

  @impl ProviderBehaviour
  def build_config(integration, decrypted, opts) do
    %{
      base_url: integration.base_url,
      client_id: decrypted.client_id,
      client_secret: decrypted.client_secret,
      meeting_id: Keyword.get(opts, :meeting_id)
    }
  end

  # The credential pair is deliberately not listed: `credential_pairs` makes a
  # credential mandatory, and these are optional. The schema encrypts
  # `client_id` and `client_secret` whenever they are present regardless.
  @impl ProviderBehaviour
  def credential_spec do
    %{required: [:base_url], credential_pairs: [], url_fields: [:base_url]}
  end

  # Checked at validation time as well as in `LinkRoom.build_room/2`, so a
  # server URL carrying a query string or fragment is refused when the
  # integration is set up rather than at the first booking.
  defp fetch_base_url(config) do
    with {:ok, base_url} <- fetch_http_base_url(Map.get(config, :base_url)),
         :ok <- LinkRoom.validate_base_url(base_url) do
      {:ok, base_url}
    end
  end

  defp fetch_http_base_url(base_url) when base_url in [nil, ""],
    do: {:error, dgettext("dashboard_integrations", "Base URL is required")}

  defp fetch_http_base_url(base_url) do
    if LinkRoom.http_url?(base_url) do
      {:ok, base_url}
    else
      {:error,
       dgettext(
         "dashboard_integrations",
         "Invalid URL format. Please provide a valid HTTP/HTTPS URL."
       )}
    end
  end

  defp validate_credentials(nil, nil), do: :ok

  defp validate_credentials(_app_id, nil),
    do:
      {:error,
       dgettext("dashboard_integrations", "Enter the App secret that belongs to this App ID")}

  defp validate_credentials(nil, _secret),
    do:
      {:error,
       dgettext("dashboard_integrations", "Enter the App ID that belongs to this App secret")}

  defp validate_credentials(_app_id, secret) when byte_size(secret) < @min_secret_bytes,
    do:
      {:error,
       dgettext(
         "dashboard_integrations",
         "The App secret must be at least %{bytes} bytes long. Every guest receives a token signed with it, so a short secret can be recovered from any booking link.",
         bytes: @min_secret_bytes
       )}

  defp validate_credentials(_app_id, _secret), do: :ok

  defp credentials(%{} = config) do
    case {present(config[:client_id]), present(config[:client_secret])} do
      {nil, _secret} -> nil
      {_app_id, nil} -> nil
      pair -> pair
    end
  end

  defp credentials(_config), do: nil

  defp mint_join_url(room_data, app_id, secret, claims) do
    case Token.mint([app_id: app_id, secret: secret, room: room_data.room_id] ++ claims) do
      {:ok, token} ->
        join_url =
          room_data.meeting_url
          |> URI.parse()
          |> URI.append_query(URI.encode_query(%{"jwt" => token}))
          |> URI.to_string()

        {:ok, join_url}

      {:error, reason} ->
        Logger.error("Failed to mint Jitsi access token, handing out the bare room URL",
          room_id: room_data.room_id,
          reason: inspect(reason)
        )

        {:ok, room_data.meeting_url}
    end
  end

  defp expiry(nil), do: DateTime.add(DateTime.utc_now(), @token_grace_seconds, :second)
  defp expiry(meeting_time), do: DateTime.add(meeting_time, @token_grace_seconds, :second)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
