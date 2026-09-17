defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider do
  @moduledoc """
  Nextcloud Talk video provider.

  Connects to a self-hosted Nextcloud with a username and an app password and
  creates one public Talk conversation per booking. The conversation's public
  link is the meeting URL for everyone: guests join it without an account, and
  the host, who owns the conversation, joins it as its moderator.

  ## Conversations

  Where the server supports it, the conversation is an *event conversation*
  bound to the booking's start and end time. Talk's own retention job deletes
  such a conversation once both its end time and its last activity are older
  than the server's `retention_event_rooms` setting, so finished bookings do
  not pile up in the host's conversation list. Support is read from the
  `config.conversations.retention-event` capability rather than from a version
  number; a server without it gets a plain public conversation instead, which
  stays until the booking is cancelled or the host removes it.

  Guests may chat, react, join a call and share audio, video and their screen,
  but they cannot start a call: only the host can. That is set through the
  conversation's default permissions right after it is created.

  ## Rescheduling

  Talk offers no way to move an event conversation's time window. A booking
  moved to an end time far enough past the original one that the retention job
  could delete the conversation before the new meeting is therefore detached
  from its event (`unbind-conversation`), turning it into a permanent public
  conversation. Its link and chat history stay the same.
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Security.SsrfBlockedError
  alias Tymeslot.Security.SsrfGuard
  alias Tymeslot.Security.UrlValidation

  @capabilities Capabilities.new!(
                  recording: false,
                  screen_sharing: true,
                  waiting_room: false,
                  max_participants: 100,
                  dial_in: false,
                  chat: true,
                  breakout_rooms: false
                )

  # Talk conversation type 3: public, joinable through its link by guests.
  @public_room_type 3

  # Attendee permission bits (Talk "constants" documentation): join call (4),
  # publish audio (16), video (32) and screen (64), post chat messages (128)
  # and add reactions (256). "Start call" (2) is deliberately left out. Talk
  # adds the "custom" bit (1) itself.
  @guest_permissions 4 + 16 + 32 + 64 + 128 + 256

  # Talk caps conversation names at 255 characters.
  @max_room_name_length 255

  # The retention job runs hourly and an administrator may shorten the
  # retention period later, so a rescheduled conversation is detached a day
  # before it could become eligible for deletion rather than at the last hour.
  @retention_safety_margin_seconds 86_400

  @typedoc """
  A tagged `perform_connection_test/1` failure. `:invalid_api_key` is the
  server rejecting the credentials; `:unreachable` covers everything that
  points at the server URL instead.
  """
  @type test_failure :: {:invalid_api_key | :unreachable, String.t()}

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :nextcloud_talk

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Nextcloud Talk"

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def connection_test_bucket, do: :nextcloud_talk

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def config_schema do
    %{
      base_url: %{type: :string, required: true, description: "Base URL of the Nextcloud server"},
      username: %{type: :string, required: true, description: "Nextcloud username"},
      app_password: %{type: :string, required: true, description: "Nextcloud app password"}
    }
  end

  # Structural validation only, as for every other provider: callers that need
  # the network run `perform_connection_test/1` or `create_meeting_room/1`
  # afterwards.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def validate_config(config) do
    with :ok <-
           ProviderConfigHelper.validate_required_fields(config, [
             :base_url,
             :username,
             :app_password
           ]) do
      validate_base_url(Map.get(config, :base_url))
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def capabilities, do: @capabilities

  @doc """
  Tests the credentials and that Talk is enabled for the account.

  Pure I/O; rate limiting is the caller's decision
  (`Tymeslot.Integrations.Video.Connection`).
  """
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, test_failure()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    with :ok <- tag_unreachable(validate_base_url(Map.get(config, :base_url))),
         {:ok, _user} <- tag_test_error(Client.get_current_user(config)),
         {:ok, capabilities} <- tag_test_error(Client.get_capabilities(config)),
         {:ok, talk} <- require_talk(capabilities) do
      {:ok, connection_success_message(talk)}
    end
  end

  defp validate_base_url(url) when url in [nil, ""],
    do: {:error, dgettext("dashboard_integrations", "Base URL is required")}

  defp validate_base_url(url) do
    UrlValidation.validate_http_url(url,
      block_private_ips: not SsrfGuard.allow_private_for_video?()
    )
  end

  defp tag_unreachable(:ok), do: :ok
  defp tag_unreachable({:error, message}), do: {:error, {:unreachable, message}}

  defp tag_test_error({:ok, _data} = ok), do: ok

  defp tag_test_error({:error, {:unauthorized, _details}}) do
    {:error,
     {:invalid_api_key,
      dgettext(
        "dashboard_integrations",
        "Authentication failed - Please check your username and app password"
      )}}
  end

  defp tag_test_error({:error, :rate_limited}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "Nextcloud is throttling requests - Please wait a moment and try again"
      )}}
  end

  defp tag_test_error({:error, {:http_error, status}}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "Nextcloud server error (status %{status}) - Please try again later",
        status: status
      )}}
  end

  defp tag_test_error({:error, {:http_error, 404, _body}}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "Nextcloud API not found - Please verify the server URL is correct"
      )}}
  end

  defp tag_test_error({:error, {:http_error, status, _body}}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "Unexpected response (status %{status}) - Please verify your configuration",
        status: status
      )}}
  end

  defp tag_test_error({:error, :invalid_response}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "The server did not answer like a Nextcloud server - Please verify the server URL"
      )}}
  end

  defp tag_test_error({:error, %SsrfBlockedError{}}) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_integrations",
        "This server address is not allowed - Private network addresses are blocked"
      )}}
  end

  defp tag_test_error({:error, exception}) when is_exception(exception) do
    {:error,
     {:unreachable,
      dgettext("dashboard_integrations", "Connection failed: %{reason}",
        reason: Exception.message(exception)
      )}}
  end

  defp tag_test_error({:error, _reason}) do
    {:error, {:unreachable, dgettext("dashboard_integrations", "Connection validation failed")}}
  end

  defp require_talk(capabilities) do
    case talk_capabilities(capabilities) do
      %{} = talk ->
        {:ok, talk}

      nil ->
        {:error,
         {:unreachable,
          dgettext(
            "dashboard_integrations",
            "Nextcloud Talk is not enabled for this account"
          )}}
    end
  end

  defp connection_success_message(%{"version" => version}) when is_binary(version) do
    dgettext("dashboard_integrations", "Connected to Nextcloud Talk %{version}", version: version)
  end

  defp connection_success_message(_talk),
    do: dgettext("dashboard_integrations", "Connected to Nextcloud Talk")

  @doc """
  Creates a public Talk conversation for a booking.

  Reads the booking's title and time from `config.event_details` (a
  `Tymeslot.Integrations.Video.EventDetails`). Without a start and end time,
  or on a server that lacks event conversations, a plain public conversation is
  created.
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    with {:ok, capabilities} <- Client.get_capabilities(config),
         talk = talk_capabilities(capabilities) || %{},
         params = room_params(config, talk),
         {:ok, room} <- Client.create_room(config, params),
         {:ok, token} <- room_token(room),
         :ok <- restrict_call_start(config, token) do
      {:ok,
       %RoomData{
         room_id: token,
         meeting_url: meeting_url(config.base_url, token),
         provider_data: %{
           "token" => token,
           "object_type" => room["objectType"],
           "object_id" => room["objectId"]
         },
         provider_config: config
       }}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create Nextcloud Talk conversation", reason: inspect(reason))
        error
    end
  end

  defp room_params(config, talk) do
    details = Map.get(config, :event_details)
    base = %{roomType: @public_room_type, roomName: room_name(details)}

    with true <- event_rooms_supported?(talk),
         {:ok, start_unix, end_unix} <- event_window(details) do
      Map.merge(base, %{objectType: "event", objectId: "#{start_unix}##{end_unix}"})
    else
      _unsupported -> base
    end
  end

  defp event_window(%{start_time: start_time, end_time: end_time}) do
    with {:ok, start_unix} <- unix_time(start_time),
         {:ok, end_unix} <- unix_time(end_time) do
      {:ok, start_unix, end_unix}
    end
  end

  defp event_window(_details), do: :no_time

  defp room_name(%{summary: summary}) when is_binary(summary) and summary != "",
    do: String.slice(summary, 0, @max_room_name_length)

  defp room_name(_details), do: "Tymeslot"

  defp room_token(%{"token" => token}) when is_binary(token) and token != "", do: {:ok, token}

  defp room_token(_room) do
    Logger.error("Nextcloud Talk returned a conversation without a token")
    {:error, :invalid_room_response}
  end

  # A conversation whose permissions could not be restricted would let guests
  # start calls, which is not what the host connected. It is removed again so
  # the job's retry starts from a clean slate instead of leaving it behind.
  defp restrict_call_start(config, token) do
    case Client.set_default_permissions(config, token, @guest_permissions) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to restrict Nextcloud Talk call permissions, removing conversation",
          reason: inspect(reason)
        )

        _cleanup = Client.delete_room(config, token)
        error
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(%RoomData{meeting_url: meeting_url}, _name, _email, _role, _time)
      when is_binary(meeting_url) and meeting_url != "" do
    # One public link serves everyone: Talk tells the host apart from guests
    # by their Nextcloud login, not by the URL.
    {:ok, meeting_url}
  end

  def create_join_url(_room_data, _name, _email, _role, _time), do: {:error, :invalid_parameters}

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) and meeting_url != "" do
    case Regex.run(~r{/call/([A-Za-z0-9]+)/?(?:[?#].*)?$}, meeting_url) do
      [_match, token] -> token
      _no_match -> nil
    end
  end

  def extract_room_id(_meeting_url), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(meeting_url) when is_binary(meeting_url) do
    case URI.parse(meeting_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        extract_room_id(meeting_url) != nil

      _other ->
        false
    end
  end

  def valid_meeting_url?(_meeting_url), do: false

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "nextcloud_talk",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url
    }
  end

  @doc """
  Keeps an event conversation alive when its booking moves later.

  Does nothing unless the conversation is still bound to an event and the new
  end time lies beyond the point where Talk's retention job could delete it
  (the stored end time plus the retention period, less a safety margin). In
  that case the conversation is detached from its event. A conversation that no
  longer exists is left alone: there is nothing to keep, and retrying would not
  bring it back.
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def update_meeting_room(room_id, config) when is_binary(room_id) do
    with {:ok, new_end_unix} <- unix_time(Map.get(config, :meeting_end_time)),
         {:ok, room} <- Client.get_room(config, room_id),
         {:ok, stored_end_unix} <- event_end_time(room),
         {:ok, capabilities} <- Client.get_capabilities(config),
         talk = talk_capabilities(capabilities) || %{},
         true <- expires_before?(talk, stored_end_unix, new_end_unix) do
      detach_from_event(config, room_id, talk)
    else
      {:error, :not_found} ->
        Logger.warning("Nextcloud Talk conversation no longer exists, nothing to update",
          room_id: room_id
        )

        :ok

      {:error, _reason} = error ->
        error

      # No new end time, not an event conversation, or no risk of expiry.
      _nothing_to_do ->
        :ok
    end
  end

  defp event_end_time(%{"objectType" => "event", "objectId" => object_id})
       when is_binary(object_id) do
    with [_start, end_time] <- String.split(object_id, "#"),
         {end_unix, ""} <- Integer.parse(end_time) do
      {:ok, end_unix}
    else
      _unparsable -> :not_bound_to_event
    end
  end

  defp event_end_time(_room), do: :not_bound_to_event

  defp expires_before?(talk, stored_end_unix, new_end_unix) do
    case retention_days(talk) do
      days when is_integer(days) and days > 0 ->
        deletable_from = stored_end_unix + days * 86_400 - @retention_safety_margin_seconds
        new_end_unix > deletable_from

      # Retention disabled (0) or unknown: Talk never expires the conversation.
      _other ->
        false
    end
  end

  defp detach_from_event(config, room_id, talk) do
    if "unbind-conversation" in Map.get(talk, "features", []) do
      Logger.info("Detaching rescheduled Nextcloud Talk conversation from its event",
        room_id: room_id
      )

      Client.unbind_room_from_object(config, room_id)
    else
      Logger.warning(
        "Rescheduled Nextcloud Talk conversation may expire before the meeting, " <>
          "but the server cannot detach it from its event",
        room_id: room_id
      )

      :ok
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def delete_meeting_room(room_id, config) when is_binary(room_id) do
    Client.delete_room(config, room_id)
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def build_config(integration, decrypted, _opts) do
    %{
      base_url: integration.base_url,
      username: decrypted.username,
      app_password: decrypted.api_key
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def credential_spec do
    %{
      required: [:base_url],
      credential_pairs: [{:username, :username_encrypted}, {:api_key, :api_key_encrypted}],
      url_fields: [:base_url]
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def url_patterns, do: ["/call/"]

  @doc """
  The public link of a conversation. The `index.php` form works whether or not
  the server has pretty URLs enabled, so it is used for every server.
  """
  @spec meeting_url(String.t(), String.t()) :: String.t()
  def meeting_url(base_url, token) do
    Client.normalize_base_url(base_url) <> "/index.php/call/" <> token
  end

  defp talk_capabilities(%{"capabilities" => %{"spreed" => %{} = talk}}), do: talk
  defp talk_capabilities(_capabilities), do: nil

  defp event_rooms_supported?(talk), do: is_integer(retention_days(talk))

  defp retention_days(talk), do: get_in(talk, ["config", "conversations", "retention-event"])

  defp unix_time(%DateTime{} = datetime), do: {:ok, DateTime.to_unix(datetime)}

  defp unix_time(%NaiveDateTime{} = naive),
    do: {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}

  defp unix_time(_other), do: :no_time
end
