defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider do
  @moduledoc """
  Nextcloud Talk video conferencing provider.

  Every booking gets its own public Talk conversation on the organiser's
  Nextcloud, created through the conversation API when the booking is
  confirmed. Guests join from its link without an account and type a display
  name. The organiser owns the conversation, so they moderate and skip the
  lobby, but only when signed in to Nextcloud in the browser they join from.
  The lobby lifts itself at the meeting's start, so early guests wait.

  A guest may join the call, speak, share video and their screen and post in
  the chat, but only the organiser opens the call, which
  `Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation`
  describes.

  The conversation token is the room id, which rescheduling and cancelling
  address: a reschedule moves the lobby timer and renames the conversation, a
  cancellation deletes it, and a scheduled clean-up deletes it some days after
  the meeting has ended. A conversation already deleted on the server counts as
  deleted, and so does one its owner marked to be preserved. A refusal that would repeat on every attempt (a 400 or 403, a
  redirect) is reported as a configuration error, which the sync job discards
  rather than retries.

  At creation, a refusal caused by the server's own settings (conversation
  creation limited to some groups, Talk limited to some groups, a password
  enforced on public conversations) carries a code of
  `Tymeslot.Integrations.Video.RoomCreationError`, which records it on the
  integration and tells its owner how to fix it. A connection test someone
  asked for, saving the integration included, refuses such a server up front
  where Talk's capabilities announce the restriction.

  Creation first looks for a conversation an earlier attempt made for the same
  booking, as `Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation`
  describes, so a retry never leaves a second one behind.

  The join link is `<server>/index.php/call/<token>`. That form works whether
  or not the server has pretty URLs configured; the shorter `/call/<token>` is
  a 404 on a server without them. The link is the same for every participant
  and never expires, so `time_bound_join_urls?/1` is not implemented.

  ## Credentials and brute-force protection

  The integration holds the server root in `base_url`, the login name in
  `client_id` and an app password in `client_secret`. Nextcloud counts every
  refused login against the calling address, and a throttled address is
  throttled for every Tymeslot user of that Nextcloud. So a 401 is never
  retried: it flags the integration `needs_reauth`, and while that flag is set
  this module refuses to send the stored credentials anywhere, since
  `build_config/3` carries the flag into every config. Saving an edit that
  changes the server, login name or app password clears it, since such an edit
  is proven against the server first; an edit that changes none of them never
  does.

  A 429, which the client reports as `:rate_limited`, is Nextcloud already
  throttling the calling address. It is not the credential's fault, so nothing
  is flagged, but it is not a fault worth retrying at once either: room
  creation passes `:rate_limited` on, which the room job snoozes on a growing
  interval, and a connection test reports it as `{:throttled, message}`, asking
  the user to wait. That tag is its own, not the `{:rate_limited, message}` of
  Tymeslot's own connection-test limiter, which means the test never ran. A
  reschedule or cancellation passes it on as well, and the sync job snoozes it
  the same way.

  The credentials never enter `RoomData.provider_data` or the meeting
  metadata; they travel only in `RoomData.provider_config`, which is never
  persisted, logged or inspected.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.NeedsReauth
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.ServerRefusals
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Security.SsrfGuard
  alias Tymeslot.Security.UrlValidation

  require Logger

  @behaviour ProviderBehaviour

  # Talk accepts the lobby in the creating call from 21.1 onwards. The server
  # announces it with this feature flag, which the connection test checks
  # instead of comparing version numbers.
  @required_feature "conversation-creation-all"

  # `video_integrations.provider_account_id` is `varchar(255)` and holds
  # `<server>||<login>`.
  @max_account_id_length 255

  @call_path "/index.php/call/"

  @capabilities Capabilities.new!(
                  waiting_room: true,
                  recording: false,
                  dial_in: false,
                  max_participants: nil,
                  breakout_rooms: false,
                  screen_sharing: true,
                  chat: true
                )

  @impl ProviderBehaviour
  def create_meeting_room(%{needs_reauth: true}), do: {:error, :unauthorized}

  def create_meeting_room(config) do
    with {:ok, data, origin} <- booking_conversation(config),
         {:ok, token} <- fetch_token(data) do
      {:ok,
       %RoomData{
         room_id: token,
         meeting_url: join_link(config.base_url, token),
         provider_data: %{base_url: config.base_url, created_at: DateTime.utc_now()},
         provider_config: config,
         adopted: origin == :adopted
       }}
    end
  end

  @impl ProviderBehaviour
  def room_creation_budget_ms, do: BookingConversation.budget_ms()

  @impl ProviderBehaviour
  def create_join_url(room_data, _participant_name, _participant_email, _role, _meeting_time),
    do: {:ok, room_data.meeting_url}

  @impl ProviderBehaviour
  def update_meeting_room(_room_id, %{needs_reauth: true}), do: {:error, :unauthorized}

  def update_meeting_room(room_id, config) when is_binary(room_id) do
    with :ok <- move_lobby(room_id, config) do
      rename(room_id, config)
    end
  end

  @impl ProviderBehaviour
  def delete_meeting_room(_room_id, %{needs_reauth: true}), do: {:error, :unauthorized}

  def delete_meeting_room(room_id, config) when is_binary(room_id) do
    case config |> credentials() |> Client.delete_room(room_id) |> tolerate_preserved(config) do
      # Already gone, which is what a delete wants: cancelling stays idempotent.
      {:error, :meeting_not_found} -> :ok
      result -> result
    end
  end

  @impl ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    with [_path, token] <- Regex.run(~r{/call/([^/]+)/?\z}, URI.parse(meeting_url).path || ""),
         true <- Client.valid_token?(token) do
      token
    else
      _not_a_call -> nil
    end
  end

  def extract_room_id(_meeting_url), do: nil

  @impl ProviderBehaviour
  def valid_meeting_url?(meeting_url),
    do: LinkRoom.http_url?(meeting_url) and extract_room_id(meeting_url) != nil

  @impl ProviderBehaviour
  def perform_connection_test(%{needs_reauth: true}) do
    {:error,
     {:unauthorized,
      dgettext(
        "dashboard_video",
        "Nextcloud refused this integration's app password earlier. Edit the integration and enter a new app password."
      )}}
  end

  def perform_connection_test(config) do
    credentials = credentials(config)

    with {:ok, _account} <- signed_in(credentials, config),
         {:ok, capabilities} <- capabilities(credentials, config) do
      check_talk(capabilities, config)
    end
  end

  @impl ProviderBehaviour
  def provider_type, do: :nextcloud_talk

  @impl ProviderBehaviour
  def display_name, do: "Nextcloud Talk"

  @impl ProviderBehaviour
  def connection_test_bucket, do: :nextcloud_talk

  @impl ProviderBehaviour
  def config_schema do
    %{
      base_url: %{type: :string, required: true, description: "Address of the Nextcloud server"},
      client_id: %{type: :string, required: true, description: "Nextcloud login name"},
      client_secret: %{type: :string, required: true, description: "Nextcloud app password"}
    }
  end

  @impl ProviderBehaviour
  def validate_config(config) do
    with {:ok, base_url} <- validate_base_url(present(config[:base_url])),
         {:ok, login} <-
           require_present(
             config[:client_id],
             dgettext("dashboard_video", "Login name is required")
           ),
         {:ok, _app_password} <-
           require_present(
             config[:client_secret],
             dgettext("dashboard_video", "App password is required")
           ) do
      validate_account_length(base_url, login)
    end
  end

  @impl ProviderBehaviour
  def capabilities, do: @capabilities

  @impl ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "nextcloud_talk",
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
      integration_id: integration.id,
      user_id: integration.user_id,
      needs_reauth: integration.needs_reauth,
      meeting_id: Keyword.get(opts, :meeting_id)
    }
  end

  @impl ProviderBehaviour
  def credential_spec do
    %{
      required: [:base_url],
      credential_pairs: [
        {:client_id, :client_id_encrypted},
        {:client_secret, :client_secret_encrypted}
      ],
      url_fields: [:base_url]
    }
  end

  @doc """
  Normalises a new or edited integration's server address, login name and app
  password, and derives the key that stops one Nextcloud account being
  connected twice: `<server>||<login>`, the shape the CalDAV integrations use.

  All three are trimmed. The server address also loses a trailing slash, its
  host is lower-cased and a default port (443 for https, 80 for http) is
  dropped, so the same server written two ways is one account. An app password
  that is not text is left for `validate_config/1` to refuse.
  """
  @spec account_attrs(map()) :: map()
  def account_attrs(attrs) do
    base_url = attrs |> Map.get(:base_url) |> trimmed() |> normalise_server()
    login = attrs |> Map.get(:client_id) |> trimmed()

    attrs
    |> Map.merge(%{
      base_url: base_url,
      client_id: login,
      provider_account_id: account_id(base_url, login)
    })
    |> trim_app_password()
  end

  # Only an http or https address with a host is rewritten, and only in its
  # scheme, host and port: a path keeps its case, and a query, fragment or login
  # stays in place for `validate_config/1` to refuse. `URI.to_string/1` leaves
  # out a port that is the scheme's default.
  defp normalise_server(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        %URI{uri | host: String.downcase(host)}
        |> URI.to_string()
        |> String.trim_trailing("/")

      _not_a_server ->
        String.trim_trailing(base_url, "/")
    end
  end

  defp trim_app_password(%{client_secret: app_password} = attrs) when is_binary(app_password),
    do: %{attrs | client_secret: String.trim(app_password)}

  defp trim_app_password(attrs), do: attrs

  defp booking_conversation(config) do
    case BookingConversation.find_or_create(credentials(config), config) do
      {:ok, data, origin} -> {:ok, data, origin}
      {:error, reason} -> {:error, creation_failure(reason, config)}
    end
  end

  # The lobby timer is what guests depend on, so it moves first, and a failure
  # to move it fails the sync.
  defp move_lobby(room_id, %{meeting_start_time: %DateTime{} = start_time} = config) do
    config
    |> credentials()
    |> Client.set_lobby(room_id, BookingConversation.lobby(start_time))
    |> lifecycle_result(config)
  end

  defp move_lobby(_room_id, _config), do: :ok

  defp rename(room_id, %{meeting_topic: topic} = config) when is_binary(topic) do
    case String.trim(topic) do
      # A blank title would rename the conversation to the generic fallback,
      # which is worse than keeping the name it has.
      "" ->
        :ok

      title ->
        config
        |> credentials()
        |> Client.rename_room(room_id, BookingConversation.room_name(title))
        |> tolerate_rename_refusal(config)
        |> lifecycle_result(config)
    end
  end

  defp rename(_room_id, _config), do: :ok

  # By the time the rename runs, the lobby has already moved. A refused rename
  # cannot be fixed by retrying, and failing the sync for it would move the
  # lobby again on every attempt, so it is logged and the sync succeeds. This
  # log names the integration, not the conversation token.
  defp tolerate_rename_refusal({:error, {:rejected, status, error}}, config) do
    Logger.warning("Nextcloud Talk refused to rename a conversation",
      integration_id: Map.get(config, :integration_id),
      status: status,
      error: error
    )

    {:ok, nil}
  end

  defp tolerate_rename_refusal(result, _config), do: result

  # Talk refuses to delete a conversation its owner marked to be preserved, and
  # the owner can lift that only in Nextcloud. Tymeslot has nothing left to do
  # for it, so the deletion counts as done; otherwise every later clean-up
  # would send the same refused request again. Any other refusal stays one.
  defp tolerate_preserved({:error, {:rejected, 403, "preserved"}}, config) do
    Logger.info("Nextcloud Talk kept a conversation its owner marked to be preserved",
      integration_id: Map.get(config, :integration_id)
    )

    :ok
  end

  defp tolerate_preserved(result, config), do: lifecycle_result(result, config)

  # What a failure during a reschedule or cancellation means for the sync job.
  # A missing conversation is reported as such, and so is a token Talk would
  # not route, which can address no conversation. A refused credential flags
  # the integration and is never retried. A 400 or 403 (a conversation type
  # Talk will not change, an account no longer allowed to moderate it) and a
  # redirect repeat on every attempt, so they are configuration errors, which
  # the sync job discards. Anything else, `:rate_limited` included, passes
  # through for the breaker and the job's retry policy to judge.
  defp lifecycle_result({:ok, _data}, _config), do: :ok
  defp lifecycle_result({:error, :not_found}, _config), do: {:error, :meeting_not_found}
  defp lifecycle_result({:error, :invalid_token}, _config), do: {:error, :meeting_not_found}

  defp lifecycle_result({:error, :unauthorized}, config) do
    flag_rejected_credentials(config)
    {:error, :unauthorized}
  end

  defp lifecycle_result({:error, {:rejected, status, _error}}, _config),
    do: {:error, {:configuration_error, {:rejected, status}}}

  defp lifecycle_result({:error, {:redirected, _location}}, _config),
    do: {:error, {:configuration_error, :redirected}}

  defp lifecycle_result({:error, reason}, _config), do: {:error, reason}

  # A token Talk would not route could never be rescheduled or cancelled, so it
  # is no room either.
  defp fetch_token(%{"token" => token}) do
    if Client.valid_token?(token), do: {:ok, token}, else: {:error, :invalid_response}
  end

  defp fetch_token(_data), do: {:error, :invalid_response}

  defp join_link(base_url, token), do: String.trim_trailing(base_url, "/") <> @call_path <> token

  # A refused credential flags the integration and is never retried. A
  # throttled address is a rate limit, which the room job snoozes rather than
  # retrying at once. Everything else is
  # `Tymeslot.Integrations.Video.Providers.NextcloudTalk.ServerRefusals`' to
  # read, since what a refusal means is Talk's own vocabulary.
  defp creation_failure(:unauthorized, config) do
    flag_rejected_credentials(config)
    :unauthorized
  end

  defp creation_failure(:rate_limited, _config), do: :rate_limited
  defp creation_failure(reason, _config), do: ServerRefusals.at_creation(reason)

  # Nextcloud answers the capabilities endpoint in full without credentials, so
  # what it says about the account is worth nothing until the login is proven.
  # A proxy that drops the Authorization header would otherwise make the save
  # fail with "this user may not create conversations" when what is wrong is
  # that nobody is signed in.
  defp signed_in(credentials, config) do
    case Client.user(credentials) do
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, connection_failure(reason, config)}
    end
  end

  defp capabilities(credentials, config) do
    case Client.capabilities(credentials) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, connection_failure(reason, config)}
    end
  end

  defp check_talk(%{"capabilities" => %{"spreed" => %{"features" => features} = spreed}}, config)
       when is_list(features) do
    with :ok <- check_version(features),
         :ok <- check_conversation_rights(spreed, config) do
      {:ok,
       String.trim(
         dgettext("dashboard_video", "Connected to Nextcloud Talk %{version}",
           version: Map.get(spreed, "version", "")
         )
       )}
    end
  end

  defp check_talk(_data, _config) do
    {:error,
     {:unreachable,
      dgettext(
        "dashboard_video",
        "Talk is not available to this account. Check that the Talk app is installed and enabled for your user."
      )}}
  end

  defp check_version(features) do
    if @required_feature in features do
      :ok
    else
      {:error,
       {:unreachable,
        dgettext(
          "dashboard_video",
          "This Nextcloud Talk is too old. Tymeslot needs Talk 21.1 or later."
        )}}
    end
  end

  # A test someone asked for (saving the integration, or the Test connection
  # button) also proves that the account may create the public conversations a
  # booking needs. The background health check does not: a server setting is
  # not a broken connection, and the room job reports it when a booking meets
  # one.
  defp check_conversation_rights(_spreed, %{connection_test_scope: :background}), do: :ok
  defp check_conversation_rights(spreed, _config), do: ServerRefusals.conversation_rights(spreed)

  defp connection_failure(:unauthorized, config) do
    flag_rejected_credentials(config)

    {:unauthorized,
     dgettext(
       "dashboard_video",
       "Nextcloud refused the login name or app password. Create an app password in Nextcloud under Personal settings, Security, and enter it with your login name."
     )}
  end

  defp connection_failure(:rate_limited, _config) do
    {:throttled,
     dgettext(
       "dashboard_video",
       "Nextcloud is refusing requests from Tymeslot for now, usually after too many failed logins. Wait a few minutes before trying again."
     )}
  end

  defp connection_failure(:not_found, _config) do
    {:unreachable,
     dgettext(
       "dashboard_video",
       "No Nextcloud answered at this address. Enter the address you open Nextcloud at, including any subfolder."
     )}
  end

  defp connection_failure({:redirected, _location}, _config) do
    {:unreachable,
     dgettext(
       "dashboard_video",
       "The server redirected the request. Enter the address your browser ends up on when you open Nextcloud, starting with https://."
     )}
  end

  defp connection_failure(:invalid_response, _config) do
    {:unreachable,
     dgettext(
       "dashboard_video",
       "The server did not answer like a Nextcloud server. Check the address."
     )}
  end

  defp connection_failure({:rejected, status, _error}, _config), do: status_failure(status)
  defp connection_failure({:http_error, status}, _config), do: status_failure(status)

  defp connection_failure(exception, _config) when is_exception(exception),
    do: unreachable_failure(Exception.message(exception))

  defp connection_failure(reason, _config), do: unreachable_failure(inspect(reason))

  defp status_failure(status) do
    {:unreachable,
     dgettext(
       "dashboard_video",
       "Nextcloud answered with status %{status}. Check the address, or try again later.",
       status: status
     )}
  end

  defp unreachable_failure(reason) do
    {:unreachable,
     dgettext("dashboard_video", "Could not reach the server: %{reason}", reason: reason)}
  end

  # Only a saved integration can be flagged. The check a new integration runs
  # before it is saved has no row; its caller shows the refusal on the form.
  # `NeedsReauth.flag/2` is the video domain's one flag-and-notify path.
  defp flag_rejected_credentials(%{integration_id: id} = config) when is_integer(id) do
    NeedsReauth.flag(config,
      label: "Nextcloud Talk",
      event: "nextcloud_talk_credentials_rejected",
      message:
        dgettext_noop(
          "dashboard_video",
          "Nextcloud refused the app password. Edit this integration and enter a new app password."
        )
    )
  end

  defp flag_rejected_credentials(_config), do: :ok

  defp validate_base_url(nil),
    do: {:error, dgettext("dashboard_video", "Base URL is required")}

  # Every request carries the app password over Basic auth, so a public server
  # must be reached over https; a server on localhost or a private network stays
  # allowed, as it is for CalDAV, and so does one on an internal name (a Docker
  # service name, `.lan`, `.home.arpa`) once the operator allows private video
  # addresses. API paths are appended to the server address,
  # so `LinkRoom.validate_base_url/1` refuses a query string or a fragment, and
  # credentials embedded in the address, which would reach guests in the link.
  defp validate_base_url(base_url) do
    allow_private = SsrfGuard.allow_private_for_video?()

    with :ok <-
           UrlValidation.validate_http_url(base_url,
             block_private_ips: not allow_private,
             enforce_https_for_public: true,
             internal_names_local: allow_private,
             https_error_message:
               dgettext(
                 "dashboard_video",
                 "Use an https:// server URL. Nextcloud receives your app password with every request."
               )
           ),
         :ok <- LinkRoom.validate_base_url(base_url) do
      {:ok, base_url}
    end
  end

  defp validate_account_length(base_url, login) do
    if String.length(account_id(String.trim_trailing(base_url, "/"), login)) <=
         @max_account_id_length do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_video",
         "The server URL and login name are too long to store together. Use a shorter server address."
       )}
    end
  end

  defp account_id(base_url, login), do: base_url <> "||" <> login

  defp credentials(config), do: Map.take(config, [:base_url, :client_id, :client_secret])

  defp require_present(value, message) do
    case present(value) do
      nil -> {:error, message}
      present -> {:ok, present}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""
end
