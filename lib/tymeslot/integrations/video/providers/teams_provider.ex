defmodule Tymeslot.Integrations.Video.Providers.TeamsProvider do
  @moduledoc """
  Microsoft Teams video conferencing provider implementation.

  Uses Microsoft Graph API to create scheduled Teams meetings with OAuth 2.0 delegated authentication.
  Provides seamless OAuth integration allowing users to create Teams meetings on their behalf.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.NeedsReauth
  alias Tymeslot.Integrations.Video.Providers.OAuthRoom
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider.Payload
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @graph_api_base_url "https://graph.microsoft.com/v1.0"

  # Room creation's requests to the provider's API. `request_timeout` caps each
  # whole response, so the budget below is a real bound; a create answers with
  # one small JSON body, so the cap waits no less than the receive timeout
  # alone did in practice. The API never redirects these requests, and one
  # that did would get a fresh budget, so redirects are refused.
  @create_request_options [receive_timeout: 45_000, request_timeout: 45_000, redirect: false]

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Microsoft Teams meeting room")
    OAuthRoom.create_meeting_room(__MODULE__, config, "Teams")
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
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def precheck_create_meeting_room(config) do
    with {:ok, :valid} <- validate_teams_scope(config) do
      OAuthRoom.classify_token_result(get_access_token(config))
    end
  end

  @doc false
  # The actual outbound Graph API call, meant to run behind the shared
  # breaker. Takes the token `precheck_create_meeting_room/1` already
  # resolved, so it never repeats the OAuth round-trip.
  @spec finish_create_meeting_room(String.t(), map()) ::
          {:ok, RoomData.t()} | {:error, term()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def finish_create_meeting_room(token, config) do
    case create_or_attach(token, config) do
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

        Logger.info("Successfully created Teams meeting",
          room_ref: Redactor.fingerprint(room_data.room_id)
        )

        {:ok, room_data}

      {:error, reason} = error ->
        log_create_meeting_room_error(reason)
        error
    end
  end

  # `:calendar_event_id` names the booking's own Outlook event when the Teams
  # account is also the calendar it was written to (see
  # `Tymeslot.Integrations.MeetingProvisioning.teams_room_placement/1`); the
  # meeting then lives on that event. Otherwise it needs an event of its own.
  defp create_or_attach(token, config) do
    case Map.get(config, :calendar_event_id) do
      event_id when is_binary(event_id) and event_id != "" ->
        attach_to_calendar_event(token, event_id, config)

      _none ->
        create_scheduled_meeting(token, config)
    end
  end

  @doc """
  Moves a room's event to the booking's new title and times.

  Only a room that is an event of its own reaches this. One attached to the
  booking's calendar event moves with that event, through calendar sync
  (`Tymeslot.Workers.VideoSyncWorker` leaves it alone).
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def update_meeting_room(room_id, config) when is_binary(room_id) do
    with {:ok, :valid} <- validate_teams_scope(config),
         {:ok, window} <- Payload.event_window(config),
         {:ok, token} <- get_access_token(config) do
      :patch
      |> graph_request(token, event_path(room_id), Payload.event_fields(window))
      |> handle_room_write(config)
    end
  end

  @doc """
  Deletes a room's event, so a cancelled booking's Teams meeting does not
  linger in the organiser's calendar. An event already gone answers
  `{:error, :meeting_not_found}`, which `ProviderAdapter` turns into `:ok`.
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def delete_meeting_room(room_id, config) when is_binary(room_id) do
    with {:ok, :valid} <- validate_teams_scope(config),
         {:ok, token} <- get_access_token(config) do
      :delete
      |> graph_request(token, event_path(room_id), nil)
      |> handle_room_write(config)
    end
  end

  @doc """
  Returns `config` carrying a usable access token, refreshed and written back
  first if the stored one has expired (see
  `Tymeslot.Integrations.Video.AccessToken`).
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def ensure_valid_token(config), do: OAuthRoom.ensure_valid_token(config, oauth_spec())

  defp log_create_meeting_room_error(reason) do
    Logger.error("Failed to create Teams meeting", error: LogFormat.reason(reason))
  end

  # The slowest creation refreshes the token (through the shared OAuth client,
  # at the HTTP client's default timeouts), creates the event and, when the
  # event came back without a Teams link, deletes it again. Attaching the
  # meeting to the booking's own event is a single PATCH, well inside that.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def room_creation_budget_ms,
    do:
      HTTPClient.request_budget_ms(:post) +
        HTTPClient.request_budget_ms(:post, @create_request_options) +
        HTTPClient.request_budget_ms(:delete, @create_request_options)

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(%{meeting_url: base_url}, participant_name, _email, _role, _meeting_time)
      when is_binary(base_url) and participant_name in [nil, ""],
      do: {:ok, base_url}

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
  def perform_connection_test(config) do
    case get_access_token(config) do
      {:ok, _token} ->
        {:ok, dgettext("integrations_video", "Microsoft Teams connected successfully!")}

      {:error, reason} ->
        {:error,
         dgettext(
           "integrations_video",
           "Failed to authenticate with Microsoft Teams: %{reason}",
           reason: inspect(reason)
         )}
    end
  end

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
    with {:ok, valid} <- OAuthRoom.ensure_valid_token(config, oauth_spec()) do
      {:ok, valid.access_token}
    end
  end

  # A refresh always asks for the Teams scope (the helper's default), not the
  # stored one, which may have come from a calendar connection and not cover
  # Teams meetings. Microsoft issues a new refresh token on each refresh, but
  # the one it replaces stays valid until its own lifetime ends. So a failed
  # write keeps a still-valid older token: the fresh access token is used, and
  # each later call refreshes again from the stored token until that one
  # expires and the integration asks to be reconnected. Failing the call
  # instead, as Zoom must (it invalidates the old token at once), would turn a
  # passing database error into a failed booking.
  defp oauth_spec do
    helper = teams_oauth_helper()

    %{
      helper: helper,
      label: "Teams",
      validate_token: &helper.validate_token/1,
      scope: fn _config -> nil end,
      persist_failure: :best_effort
    }
  end

  # A room of its own: a new event in the Teams account's default calendar
  # that carries the meeting, titled and timed as the booking is.
  defp create_scheduled_meeting(token, config) do
    with {:ok, window} <- Payload.event_window(config) do
      :post
      |> graph_request(token, "/me/events", Payload.new_event(window, config))
      |> handle_room_event(token, config, :own_event)
    end
  end

  # The booking's own calendar event, made into the Teams meeting, so the
  # organiser's calendar holds one entry for the booking rather than two.
  defp attach_to_calendar_event(token, event_id, config) do
    :patch
    |> graph_request(token, event_path(event_id), Payload.online_meeting(config))
    |> handle_room_event(token, config, :calendar_event)
  end

  defp handle_room_event({:ok, %Req.Response{status: status, body: body}}, token, _config, owner)
       when status in [200, 201] do
    case decode_body(body) do
      {:ok, event} -> extract_join_info(token, event, owner)
      error -> error
    end
  end

  defp handle_room_event(response, _token, config, _owner),
    do: handle_failed_write(response, config)

  # The access token was rejected by Graph even though it had survived token
  # validation/refresh, which means server-side revocation or a consent
  # withdrawal. Flag the integration so the dashboard surfaces the "Reconnect
  # required" badge immediately, rather than waiting for the async HealthCheck
  # cycle. Mirrors Zoom's flag_revoked_token/1.
  defp handle_failed_write({:ok, %Req.Response{status: 401, body: body}}, config) do
    flag_revoked_token(config)
    decode_and_format_error(401, body)
  end

  defp handle_failed_write({:ok, %Req.Response{status: status, body: body}}, _config),
    do: decode_and_format_error(status, body)

  # Passed through raw (a `%Req.TransportError{}`/`%Mint.*{}` struct or a
  # transport reason atom) rather than flattened to prose, so `BreakerOutcome`
  # recognises a genuine transport failure and lets the breaker witness it.
  defp handle_failed_write({:error, reason}, _config), do: {:error, reason}

  # A room's later writes (a reschedule, a cancellation) only need to land: a
  # 404 is the room already gone, which a delete counts as done.
  defp handle_room_write({:ok, %Req.Response{status: status}}, _config) when status in 200..299,
    do: :ok

  defp handle_room_write({:ok, %Req.Response{status: 404}}, _config),
    do: {:error, :meeting_not_found}

  defp handle_room_write(response, config), do: handle_failed_write(response, config)

  # Flags the integration as needing reauthentication after a 401 from Graph —
  # i.e. the credentials are no longer accepted server-side. The dashboard
  # surfaces this via the "Reconnect required" badge on the video row. Purely
  # additive: it does not touch token validation or the refresh.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def flag_revoked_token(config) do
    NeedsReauth.flag(config,
      label: "Teams",
      event: "teams_token_revoked",
      message:
        dgettext_noop(
          "integrations_video",
          "Microsoft Teams access was revoked. Please reconnect your Teams account."
        )
    )
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp extract_join_info(token, event, owner) do
    case Payload.join_url(event) do
      nil ->
        discard_linkless_event(token, event["id"], owner)

        # A tagged reason rather than a sentence: the caller's error policy
        # has to recognise this as terminal, and it cannot match on prose.
        {:error, :video_meeting_not_enabled}

      join_url ->
        {:ok,
         %{
           "id" => event["id"],
           "joinUrl" => join_url,
           "joinWebUrl" => join_url,
           "videoTeleconferenceId" => nil,
           "passcode" => nil
         }}
    end
  end

  # Graph answered, so the event exists on the account even though it carries
  # no Teams link: the account cannot host Teams meetings. An event of the
  # room's own is removed, or every attempt would deposit another placeholder
  # in the organiser's calendar. The booking's own event is left alone: it is
  # the booking, and calendar sync owns it.
  defp discard_linkless_event(_token, _event_id, :calendar_event), do: :ok

  defp discard_linkless_event(token, event_id, :own_event),
    do: delete_orphaned_event(token, event_id)

  # Best-effort: the room creation has already failed and the caller's outcome
  # does not change either way, so a failed cleanup is logged, never raised.
  defp delete_orphaned_event(_token, nil), do: :ok

  defp delete_orphaned_event(token, event_id) do
    case graph_request(:delete, token, event_path(event_id), nil) do
      {:ok, %Req.Response{status: status}} when status in [200, 202, 204] ->
        Logger.info("Deleted Teams calendar event left without a join link")
        :ok

      other ->
        Logger.warning("Could not delete Teams calendar event left without a join link",
          result: LogFormat.reason(other)
        )

        :ok
    end
  end

  defp graph_request(method, token, path, body) do
    Config.http_client_module().request(
      method,
      @graph_api_base_url <> path,
      encode_body(body),
      graph_headers(token),
      @create_request_options
    )
  end

  defp encode_body(nil), do: ""
  defp encode_body(body), do: Jason.encode!(body)

  # Graph ids are base64-like and may carry `/`, `+` or `=`, which must not
  # reach the path unescaped.
  defp event_path(event_id), do: "/me/events/#{URI.encode(event_id, &URI.char_unreserved?/1)}"

  defp graph_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp teams_oauth_helper do
    Application.get_env(:tymeslot, :teams_oauth_helper, TeamsOAuthHelper)
  end

  # Formats a Teams/Graph API error response into an `{:error, {:http_error,
  # status, message}}` tuple. Tagged with `status` (rather than flattened to
  # prose) so `BreakerOutcome` can tell a genuine outage (5xx/429/408) from a
  # request problem and let the breaker witness it.
  defp decode_and_format_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        message = error["message"] || "Unknown error"
        code = error["code"] || "Unknown"

        # Graph's own message/code are provider-supplied and can echo request
        # fragments, so they are redacted and bounded before they reach the
        # returned reason (and, downstream, a log line or Oban's stored error).
        detail = Redactor.redact_and_truncate("#{code} - #{message}", 512)

        # Check if this is an authentication error that might be due to missing scopes
        error_message =
          if code == "AuthenticationError" do
            "Teams API error (#{status}): #{detail}. " <>
              "This usually means the integration needs to be re-authenticated with Teams-specific permissions. " <>
              "Please disconnect and reconnect your Microsoft Teams integration in the dashboard."
          else
            "Teams API error (#{status}): #{detail}"
          end

        {:error, {:http_error, status, error_message}}

      _other ->
        # Undecodable body: still bounded and scrubbed before it reaches a log
        # line, so a provider that answers with something unexpected cannot
        # write an unbounded blob (or whatever it happens to contain) to disk.
        {:error,
         {:http_error, status,
          "Failed to create meeting with status #{status}: " <>
            Redactor.redact_and_truncate(body)}}
    end
  end
end
