defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider do
  @moduledoc """
  Zoom video conferencing provider.

  Uses the Zoom REST API v2 with OAuth 2.0 user-managed authentication
  to create scheduled Zoom meetings on the connected user's account.
  Zoom is not a calendar provider — the join URL is embedded into
  calendar events created by the user's calendar provider.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Payload
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @api_base_url "https://api.zoom.us/v2"
  @zoom_url_pattern ~r/zoom\.us\/(j|my|w)\//

  @capabilities Capabilities.new!(
                  waiting_room: true,
                  recording: true,
                  dial_in: true,
                  max_participants: 100,
                  breakout_rooms: true,
                  screen_sharing: true,
                  chat: true
                )

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Zoom meeting room")

    with {:ok, :valid} <- validate_zoom_scope(config),
         {:ok, token} <- get_access_token(config),
         {:ok, {start_time, end_time}} <- Payload.get_meeting_times(config),
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

      Logger.info("Successfully created Zoom meeting", room_id: room_data.room_id)
      {:ok, room_data}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create Zoom meeting", error: inspect(reason))
        error
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, _participant_email, _role, _meeting_time) do
    case room_data.meeting_url do
      nil ->
        {:error, "Missing meeting URL in room data"}

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
  def valid_meeting_url?(meeting_url), do: meeting_url =~ @zoom_url_pattern

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def test_connection(config) do
    case get_access_token(config) do
      {:ok, _token} -> {:ok, "Successfully authenticated with Zoom"}
      {:error, reason} -> {:error, "Failed to authenticate with Zoom: #{inspect(reason)}"}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :zoom

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Zoom"

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
  def capabilities, do: @capabilities

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(:meeting_ended, room_data, _additional_data) do
    Logger.info("Zoom meeting ended", room_id: room_data.room_id)
    :ok
  end

  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "zoom",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url,
      passcode: room_data.provider_data[:passcode],
      host_url: room_data.provider_data[:start_url]
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
  def url_patterns, do: ["zoom.us"]

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def update_meeting_room(room_id, config) when is_binary(room_id) do
    Logger.info("Updating Zoom meeting room", room_id: room_id)

    with {:ok, :valid} <- validate_zoom_scope(config),
         {:ok, token} <- get_access_token(config),
         {:ok, {start_time, end_time}} <- Payload.get_meeting_times(config),
         :ok <- patch_scheduled_meeting(token, room_id, start_time, end_time, config) do
      Logger.info("Successfully updated Zoom meeting", room_id: room_id)
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to update Zoom meeting",
          room_id: room_id,
          error: inspect(reason)
        )

        error
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def delete_meeting_room(room_id, config) when is_binary(room_id) do
    Logger.info("Deleting Zoom meeting room", room_id: room_id)

    with {:ok, :valid} <- validate_zoom_scope(config),
         {:ok, token} <- get_access_token(config),
         :ok <- delete_scheduled_meeting(token, room_id, config) do
      Logger.info("Successfully deleted Zoom meeting", room_id: room_id)
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to delete Zoom meeting",
          room_id: room_id,
          error: inspect(reason)
        )

        error
    end
  end

  # ----- Private -----

  # Zoom apps may be configured with either classic scopes (`meeting:write`) or
  # the newer granular scopes (`meeting:write:meeting`). Both grant the ability
  # to create/update meetings, so accept either to avoid locking out classic-
  # scope apps that can otherwise create meetings perfectly well.
  defp validate_zoom_scope(config) do
    stored_scope = String.downcase(Map.get(config, :oauth_scope) || "")

    granular? = String.contains?(stored_scope, "meeting:write:meeting")
    classic? = scope_present?(stored_scope, "meeting:write")

    if granular? or classic? do
      {:ok, :valid}
    else
      Logger.error("Zoom integration missing required scope",
        stored_scope: stored_scope,
        required_scope: "meeting:write or meeting:write:meeting"
      )

      {:error, "Zoom scopes are insufficient. Please reconnect your Zoom account."}
    end
  end

  # Matches a whole space-delimited scope token exactly, so a search for the
  # classic `meeting:write` is not satisfied by an unrelated longer scope that
  # merely contains it as a substring.
  defp scope_present?(stored_scope, scope) do
    stored_scope
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?(scope)
  end

  defp get_access_token(config) do
    case zoom_oauth_helper().validate_token(config) do
      {:ok, :valid} ->
        {:ok, Map.get(config, :access_token)}

      {:ok, :needs_refresh} ->
        refresh_and_update_token(config)

      {:error, reason} ->
        Logger.error("Zoom token validation failed", reason: inspect(reason))
        {:error, "Token validation failed: #{reason}"}
    end
  end

  defp refresh_and_update_token(config, opts \\ []) do
    OAuthTokenManager.refresh_with_lock(
      config,
      %{
        provider: :zoom,
        refresh: &perform_refresh/1,
        already_refreshed: fn _config, decrypted -> {:ok, decrypted.access_token} end
      },
      opts
    )
  end

  defp perform_refresh(config) do
    case do_actual_refresh(config) do
      {:ok, refreshed} -> {:ok, refreshed.access_token}
      error -> error
    end
  end

  defp do_actual_refresh(config) do
    refresh_token = Map.get(config, :refresh_token)

    case zoom_oauth_helper().refresh_access_token(refresh_token, nil) do
      {:ok, refreshed} ->
        Logger.info("Successfully refreshed Zoom OAuth token")
        persist_refreshed_tokens(config, refreshed)

      {:error, reason} ->
        Logger.error("Failed to refresh Zoom OAuth token", reason: inspect(reason))
        {:error, "Token refresh failed: #{reason}"}
    end
  end

  defp persist_refreshed_tokens(config, refreshed) do
    case Map.get(config, :integration_id) do
      nil ->
        {:ok, refreshed}

      integration_id ->
        case update_integration_tokens(integration_id, Map.get(config, :user_id), refreshed) do
          :ok -> {:ok, refreshed}
          {:error, _reason} -> {:error, :token_persist_failed}
        end
    end
  end

  defp update_integration_tokens(integration_id, user_id, refreshed) do
    # Zoom rotates refresh tokens on every refresh, but if the response omits a
    # new one we keep the existing refresh token rather than poisoning the field
    # with the access token (which would break the next refresh entirely).
    attrs =
      maybe_put_refresh_token(
        %{
          access_token: refreshed.access_token,
          token_expires_at: refreshed.expires_at
        },
        refreshed.refresh_token
      )

    attrs =
      case refreshed[:scope] do
        nil -> attrs
        "" -> attrs
        scope -> Map.put(attrs, :oauth_scope, scope)
      end

    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} ->
        case VideoIntegrationQueries.update(integration, attrs) do
          {:ok, _updated} ->
            Logger.info("Updated Zoom OAuth tokens", integration_id: integration_id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to persist Zoom tokens",
              integration_id: integration_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Zoom integration vanished before token update",
          integration_id: integration_id
        )

        :ok
    end
  end

  # Only overwrite the stored refresh token when Zoom returned a fresh one. A
  # blank/missing value means the previous refresh token is still valid, so we
  # leave the column untouched rather than clobbering it.
  defp maybe_put_refresh_token(attrs, refresh_token)
       when is_binary(refresh_token) and refresh_token != "",
       do: Map.put(attrs, :refresh_token, refresh_token)

  defp maybe_put_refresh_token(attrs, _refresh_token), do: attrs

  defp create_scheduled_meeting(token, start_time, end_time, config) do
    duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
    payload = Payload.build_meeting_payload(start_time, duration, config)

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@api_base_url}/users/me/meetings"

    case Config.http_client_module().request(:post, url, Jason.encode!(payload), headers, []) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        Payload.parse_meeting_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Payload.decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
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

    case Config.http_client_module().request(:get, url, "", headers, []) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.info("Verified Zoom meeting",
          room_id: to_string(meeting_id),
          meeting_status: read_meeting_status(body)
        )

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Could not verify Zoom meeting after creation",
          room_id: to_string(meeting_id),
          http_status: status
        )

      {:error, reason} ->
        Logger.warning("Network error verifying Zoom meeting after creation",
          room_id: to_string(meeting_id),
          error: inspect(reason)
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
          room_id: room_id,
          body: inspect(response_body)
        )

        {:error, :meeting_not_found}

      {:ok, %Req.Response{status: 401, body: _body}} ->
        # Token may have been server-side revoked. Attempt one forced refresh
        # and retry the already-built body. If refresh fails or the retry also
        # returns 401, flag the integration for reauthentication.
        retry_after_401(:patch, room_id, config, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Payload.decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  # Shared retry-after-token-refresh path for the PATCH (reschedule) and DELETE
  # (cancel) requests. Both attempt one forced refresh, replay the request with
  # the fresh token, and flag the integration for reauthentication if the retry
  # still returns 401 (server-side revocation) or the refresh itself fails. The
  # verb drives the request body and which statuses count as success.
  defp retry_after_401(verb, room_id, config, body) do
    # Force an actual OAuth refresh: the access token was rejected server-side,
    # so the DB validity buffer can't be trusted to short-circuit the refresh.
    case refresh_and_update_token(config, force: true) do
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
            flag_revoked_token(config)
            Payload.decode_and_format_error(401, response_body)

          response ->
            handle_verb_response(verb, room_id, response)
        end

      {:error, _reason} ->
        # Refresh itself failed — credentials are no longer usable.
        flag_revoked_token(config)
        {:error, "Zoom token refresh failed after 401. Please reconnect your Zoom account."}
    end
  end

  defp request_headers(:patch, token),
    do: [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]

  defp request_headers(:delete, token), do: [{"Authorization", "Bearer #{token}"}]

  defp handle_verb_response(:patch, room_id, response) do
    case response do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        Logger.warning("Zoom meeting no longer exists on reschedule retry",
          room_id: room_id
        )

        {:error, :meeting_not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        Payload.decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp handle_verb_response(:delete, room_id, response) do
    case response do
      {:ok, %Req.Response{status: status}} when status in [204, 200] ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        Logger.info("Zoom meeting already deleted", room_id: room_id)
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Payload.decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

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
        retry_after_401(:delete, room_id, config, "")

      # 204/200 success, 404 "already gone" (idempotent), and other errors all
      # share the delete-verb handling used by the post-401 retry path.
      response ->
        handle_verb_response(:delete, room_id, response)
    end
  end

  # Flags the integration as needing reauthentication after a 401 that survived
  # a forced token refresh — this indicates server-side revocation at zoom.us.
  # The dashboard surfaces this via the "Reconnect required" badge on the video row.
  defp flag_revoked_token(config) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      Logger.warning("Zoom token appears revoked but no integration_id to flag",
        event: "zoom_token_revoked"
      )
    else
      Logger.warning("Zoom token revoked; flagging integration for reauth",
        event: "zoom_token_revoked",
        integration_id: integration_id
      )

      case Video.fetch_integration_for_user(integration_id, user_id) do
        {:ok, integration} ->
          VideoIntegrationQueries.mark_needs_reauth(
            integration,
            "Zoom access was revoked. Please reconnect your Zoom account."
          )

        {:error, :not_found} ->
          :ok
      end
    end
  end

  defp zoom_oauth_helper do
    Application.get_env(:tymeslot, :zoom_oauth_helper, ZoomOAuthHelper)
  end
end
