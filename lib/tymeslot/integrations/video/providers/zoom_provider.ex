defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider do
  @moduledoc """
  Zoom video conferencing provider.

  Uses the Zoom REST API v2 with OAuth 2.0 user-managed authentication
  to create scheduled Zoom meetings on the connected user's account.
  Zoom is not a calendar provider — the join URL is embedded into
  calendar events created by the user's calendar provider.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.OAuthCredentials
  alias Tymeslot.Integrations.Video.Providers.OAuthRoom
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Payload
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Reauth
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @api_base_url "https://api.zoom.us/v2"

  # Room creation's requests to the provider's API. `request_timeout` caps each
  # whole response, so the budget below is a real bound; a create answers with
  # one small JSON body, so the cap waits no less than the receive timeout
  # alone did in practice. The API never redirects these requests, and one
  # that did would get a fresh budget, so redirects are refused.
  @create_request_options [receive_timeout: 45_000, request_timeout: 45_000, redirect: false]

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Zoom meeting room")
    OAuthRoom.create_meeting_room(__MODULE__, config, "Zoom")
  end

  @doc false
  # Pre-flight phase for `ProviderAdapter`'s circuit-breaker split (see the
  # comment on `ProviderAdapter.with_breaker/2`). Runs before the shared Zoom
  # breaker is ever asked for permission.
  #
  # Scope validation is pure, no network at all, so it can never represent
  # Zoom being down. Token acquisition *is* network I/O, but against Zoom's
  # OAuth host rather than its meetings API, and its failures are classified
  # before they reach the breaker: a rejected/expired grant is the tenant's
  # problem (`{:error, _}`, bypasses the breaker entirely), while anything
  # else — a timeout or 5xx from the OAuth host — comes back as
  # `{:provider_error, _}` so the caller can still let the breaker witness it.
  @spec precheck_create_meeting_room(map()) ::
          {:ok, String.t()} | {:error, term()} | {:provider_error, term()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def precheck_create_meeting_room(config) do
    with {:ok, :valid} <- Reauth.validate_scope(config, :write) do
      OAuthRoom.classify_token_result(get_access_token(config))
    end
  end

  @doc false
  # The actual outbound Zoom API call, meant to run behind the shared
  # breaker. Takes the token `precheck_create_meeting_room/1` already
  # resolved, so it never repeats the OAuth round-trip.
  @spec finish_create_meeting_room(String.t(), map()) ::
          {:ok, RoomData.t()} | {:error, term()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def finish_create_meeting_room(token, config) do
    with {:ok, {start_time, end_time}} <- Payload.get_meeting_times(config),
         {:ok, meeting} <- create_scheduled_meeting(token, start_time, end_time, config) do
      # Read the meeting back from Zoom to confirm it is retrievable before we
      # hand the join link to attendees. Exercises the meeting:read:meeting
      # scope and is best-effort: the meeting already exists, so a failed read
      # only warrants a log line, never a failed booking.
      verify_meeting_created(token, meeting["id"])

      room_data = %RoomData{
        room_id: to_string(meeting["id"]),
        meeting_url: meeting["join_url"],
        provider_data: %{
          passcode: meeting["password"],
          start_url: meeting["start_url"],
          host_email: meeting["host_email"]
        }
      }

      Logger.info("Successfully created Zoom meeting",
        room_ref: Redactor.fingerprint(room_data.room_id)
      )

      {:ok, room_data}
    else
      {:error, reason} = error ->
        log_create_meeting_room_error(reason)
        error
    end
  end

  defp log_create_meeting_room_error(reason) do
    Logger.error("Failed to create Zoom meeting", error: LogFormat.reason(reason))
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def flag_revoked_token(config), do: Reauth.flag_revoked_token(config)

  @doc """
  Returns `config` carrying a usable access token, refreshed and written back
  first if the stored one has expired (see
  `Tymeslot.Integrations.Video.AccessToken`).
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def ensure_valid_token(config), do: OAuthRoom.ensure_valid_token(config, oauth_spec())

  # The slowest creation refreshes the token (through the shared OAuth client,
  # at the HTTP client's default timeouts), creates the meeting and reads it
  # back.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def room_creation_budget_ms,
    do:
      HTTPClient.request_budget_ms(:post) +
        HTTPClient.request_budget_ms(:post, @create_request_options) +
        HTTPClient.request_budget_ms(:get, @create_request_options)

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, _participant_email, _role, _meeting_time) do
    case room_data.meeting_url do
      nil ->
        {:error, "Missing meeting URL in room data"}

      # Nobody to name: the room's own link is the participant's link.
      base_url when participant_name in [nil, ""] ->
        {:ok, base_url}

      base_url ->
        encoded_name = URI.encode_www_form(participant_name)

        url =
          if String.contains?(base_url, "?") do
            "#{base_url}&uname=#{encoded_name}"
          else
            "#{base_url}?uname=#{encoded_name}"
          end

        {:ok, url}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    case Regex.run(~r/zoom\.us\/(?:j|my|w)\/(\d+)/, meeting_url) do
      [_full, id] -> id
      _no_match -> nil
    end
  end

  def extract_room_id(_other), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    case get_access_token(config) do
      {:ok, _token} ->
        {:ok, dgettext("integrations_video", "Zoom connected successfully!")}

      {:error, reason} ->
        {:error,
         dgettext("integrations_video", "Failed to authenticate with Zoom: %{reason}",
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
      access_token: %{type: :string, required: true, description: "Zoom OAuth access token"},
      refresh_token: %{type: :string, required: true, description: "Zoom OAuth refresh token"},
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
  defdelegate build_config(integration, decrypted, opts), to: OAuthCredentials

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  defdelegate credential_spec, to: OAuthCredentials

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def update_meeting_room(room_id, config) when is_binary(room_id) do
    Logger.info("Updating Zoom meeting room", room_ref: Redactor.fingerprint(room_id))

    with {:ok, :valid} <- Reauth.validate_scope(config, :update),
         {:ok, token} <- get_access_token(config),
         {:ok, {start_time, end_time}} <- Payload.get_meeting_times(config),
         :ok <- patch_scheduled_meeting(token, room_id, start_time, end_time, config) do
      Logger.info("Successfully updated Zoom meeting", room_ref: Redactor.fingerprint(room_id))
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to update Zoom meeting",
          room_ref: Redactor.fingerprint(room_id),
          error: LogFormat.reason(reason)
        )

        error
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def delete_meeting_room(room_id, config) when is_binary(room_id) do
    Logger.info("Deleting Zoom meeting room", room_ref: Redactor.fingerprint(room_id))

    with {:ok, :valid} <- Reauth.validate_scope(config, :delete),
         {:ok, token} <- get_access_token(config),
         :ok <- delete_scheduled_meeting(token, room_id, config) do
      Logger.info("Successfully deleted Zoom meeting", room_ref: Redactor.fingerprint(room_id))
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to delete Zoom meeting",
          room_ref: Redactor.fingerprint(room_id),
          error: LogFormat.reason(reason)
        )

        error
    end
  end

  # ----- Private -----

  defp get_access_token(config, opts \\ []) do
    with {:ok, valid} <- OAuthRoom.ensure_valid_token(config, oauth_spec(), opts) do
      {:ok, valid.access_token}
    end
  end

  # Zoom rotates its refresh token on every refresh, so a token it cannot
  # write back is one zoom.us has already invalidated: a failed write fails
  # the refresh.
  defp oauth_spec do
    helper = zoom_oauth_helper()

    %{
      helper: helper,
      label: "Zoom",
      validate_token: &helper.validate_token/1,
      scope: fn _config -> nil end,
      persist_failure: :fatal
    }
  end

  defp create_scheduled_meeting(token, start_time, end_time, config) do
    duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
    payload = Payload.build_meeting_payload(start_time, duration, config)

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@api_base_url}/users/me/meetings"

    case Config.http_client_module().request(
           :post,
           url,
           Jason.encode!(payload),
           headers,
           @create_request_options
         ) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        Payload.parse_meeting_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Payload.decode_and_format_error(status, body)

      {:error, reason} ->
        # Passed through raw (a `%Req.TransportError{}`/`%Mint.*{}` struct or a
        # transport reason atom) rather than flattened to prose, so
        # `BreakerOutcome` recognises a genuine transport failure and lets the
        # breaker witness it.
        {:error, reason}
    end
  end

  # Best-effort read-back of a freshly created meeting via GET /meetings/{id}.
  # Confirms the meeting is retrievable and exercises the meeting:read:meeting
  # scope. Returns :ok regardless of outcome — the meeting already exists, so a
  # failed verification must not fail the booking.
  defp verify_meeting_created(_token, nil), do: :ok

  defp verify_meeting_created(token, meeting_id) do
    headers = [{"Authorization", "Bearer #{token}"}]
    url = "#{@api_base_url}/meetings/#{meeting_id}"

    case Config.http_client_module().request(:get, url, "", headers, @create_request_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.info("Verified Zoom meeting",
          room_ref: Redactor.fingerprint(to_string(meeting_id)),
          meeting_status: read_meeting_status(body)
        )

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Could not verify Zoom meeting after creation",
          room_ref: Redactor.fingerprint(to_string(meeting_id)),
          http_status: status
        )

      {:error, reason} ->
        Logger.warning("Network error verifying Zoom meeting after creation",
          room_ref: Redactor.fingerprint(to_string(meeting_id)),
          error: LogFormat.reason(reason)
        )
    end
  end

  defp read_meeting_status(body) do
    case Jason.decode(body) do
      {:ok, %{"status" => status}} -> status
      _other -> "unknown"
    end
  end

  defp patch_scheduled_meeting(token, room_id, start_time, end_time, config) do
    duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
    body = Jason.encode!(Payload.build_meeting_payload(start_time, duration, config))
    url = "#{@api_base_url}/meetings/#{room_id}"

    case Config.http_client_module().request(
           :patch,
           url,
           body,
           request_headers(:patch, token),
           []
         ) do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: 404, body: response_body}} ->
        Logger.warning("Zoom meeting no longer exists on reschedule",
          room_ref: Redactor.fingerprint(room_id),
          body: Redactor.redact_and_truncate(response_body)
        )

        {:error, :meeting_not_found}

      {:ok, %Req.Response{status: 401, body: _body}} ->
        # Token may have been server-side revoked. Attempt one forced refresh
        # and retry the already-built body. If refresh fails or the retry also
        # returns 401, flag the integration for reauthentication.
        retry_after_401(:patch, room_id, config, body, token)

      # Everything else — including the 400/4711 that means the grant lacks
      # `meeting:update:meeting` — shares the update-verb error handling used by
      # the post-401 retry path, so a scope rejection is recognised on the first
      # attempt rather than retried as though it were transient.
      response ->
        handle_error_response(response, config, :update)
    end
  end

  # Shared retry-after-token-refresh path for the PATCH (reschedule) and DELETE
  # (cancel) requests. Both attempt one forced refresh, replay the request with
  # the fresh token, and flag the integration for reauthentication if the retry
  # still returns 401 (server-side revocation) or the refresh itself fails. The
  # verb drives the request body and which statuses count as success.
  defp retry_after_401(verb, room_id, config, body, refused_token) do
    # Force an actual OAuth refresh: the access token was rejected server-side,
    # so the DB validity buffer can't be trusted to short-circuit the refresh.
    # The refused token is the one this request sent, which may be newer than
    # the config's if the operation refreshed at its start.
    case get_access_token(config, refused_token: refused_token) do
      {:ok, fresh_token} ->
        url = "#{@api_base_url}/meetings/#{room_id}"

        case Config.http_client_module().request(
               verb,
               url,
               body,
               request_headers(verb, fresh_token),
               []
             ) do
          {:ok, %Req.Response{status: 401, body: response_body}} ->
            # Refresh succeeded but Zoom still rejects — token is revoked.
            Reauth.flag_revoked_token(config)
            Payload.decode_and_format_error(401, response_body)

          response ->
            handle_verb_response(verb, room_id, config, response)
        end

      {:error, _reason} ->
        # Refresh itself failed — credentials are no longer usable.
        Reauth.flag_revoked_token(config)

        {:error,
         dgettext(
           "integrations_video",
           "Zoom token refresh failed after 401. Please reconnect your Zoom account."
         )}
    end
  end

  defp request_headers(:patch, token),
    do: [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]

  defp request_headers(:delete, token), do: [{"Authorization", "Bearer #{token}"}]

  defp handle_verb_response(:patch, room_id, config, response) do
    case response do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        Logger.warning("Zoom meeting no longer exists on reschedule retry",
          room_ref: Redactor.fingerprint(room_id)
        )

        {:error, :meeting_not_found}

      other ->
        handle_error_response(other, config, :update)
    end
  end

  defp handle_verb_response(:delete, room_id, config, response) do
    case response do
      {:ok, %Req.Response{status: status}} when status in [204, 200] ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        Logger.info("Zoom meeting already deleted", room_ref: Redactor.fingerprint(room_id))
        :ok

      other ->
        handle_error_response(other, config, :delete)
    end
  end

  # Zoom answers a request whose token was granted before a scope was added
  # with code 4711. Retrying cannot widen an existing grant — only the user
  # re-consenting can — so flag the integration and return a reason callers can
  # discard on rather than burning their whole retry budget.
  defp handle_error_response({:ok, %Req.Response{status: status, body: body}}, config, operation) do
    if Scopes.rejection?(body) do
      Logger.error("Zoom rejected the request for missing scope",
        operation: operation,
        status: status
      )

      Reauth.flag_missing_scope(config, operation)
      {:error, :insufficient_scope}
    else
      Payload.decode_and_format_error(status, body)
    end
  end

  defp handle_error_response({:error, reason}, _config, _operation),
    do: {:error, reason}

  defp delete_scheduled_meeting(token, room_id, config) do
    url = "#{@api_base_url}/meetings/#{room_id}"

    case Config.http_client_module().request(
           :delete,
           url,
           "",
           request_headers(:delete, token),
           []
         ) do
      {:ok, %Req.Response{status: 401, body: _body}} ->
        # Token may have been server-side revoked. Attempt one forced refresh
        # and retry. If refresh fails or the retry also returns 401, flag the
        # integration for reauthentication.
        retry_after_401(:delete, room_id, config, "", token)

      # 204/200 success, 404 "already gone" (idempotent), and other errors all
      # share the delete-verb handling used by the post-401 retry path.
      response ->
        handle_verb_response(:delete, room_id, config, response)
    end
  end

  defp zoom_oauth_helper do
    Application.get_env(:tymeslot, :zoom_oauth_helper, ZoomOAuthHelper)
  end
end
