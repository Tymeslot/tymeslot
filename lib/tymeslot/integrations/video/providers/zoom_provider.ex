defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider do
  @moduledoc """
  Zoom video conferencing provider.

  Uses the Zoom REST API v2 with OAuth 2.0 user-managed authentication
  to create scheduled Zoom meetings on the connected user's account.
  Zoom is not a calendar provider — the join URL is embedded into
  calendar events created by the user's calendar provider.
  """

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  require Logger

  @behaviour ProviderBehaviour

  @api_base_url "https://api.zoom.us/v2"
  @zoom_url_pattern ~r/zoom\.us\/(j|my|w)\//

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating Zoom meeting room")

    with {:ok, :valid} <- validate_zoom_scope(config),
         {:ok, token} <- get_access_token(config),
         {:ok, {start_time, end_time}} <- get_meeting_times(config),
         {:ok, meeting} <- create_scheduled_meeting(token, start_time, end_time, config) do
      room_data = %{
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
        url =
          if String.contains?(base_url, "?") do
            "#{base_url}&uname=#{URI.encode(participant_name)}"
          else
            "#{base_url}?uname=#{URI.encode(participant_name)}"
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

  def extract_room_id(%{room_data: room_data}),
    do: room_data[:room_id] || room_data["room_id"]

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
      passcode: room_data.provider_data[:passcode] || room_data.provider_data["passcode"],
      host_url: room_data.provider_data[:start_url] || room_data.provider_data["start_url"]
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def update_meeting_room(room_id, config) when is_binary(room_id) do
    Logger.info("Updating Zoom meeting room", room_id: room_id)

    with {:ok, :valid} <- validate_zoom_scope(config),
         {:ok, token} <- get_access_token(config),
         {:ok, {start_time, end_time}} <- get_meeting_times(config),
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

  defp validate_zoom_scope(config) do
    stored_scope = Map.get(config, :oauth_scope) || ""
    required_scope = "meeting:write:meeting"

    if String.contains?(String.downcase(stored_scope), required_scope) do
      {:ok, :valid}
    else
      Logger.error("Zoom integration missing required scope",
        stored_scope: stored_scope,
        required_scope: required_scope
      )

      {:error, "Zoom scopes are insufficient. Please reconnect your Zoom account."}
    end
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

  defp refresh_and_update_token(config) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      case do_actual_refresh(config) do
        {:ok, refreshed} -> {:ok, refreshed.access_token}
        error -> error
      end
    else
      Lock.with_lock(
        {:zoom, integration_id},
        fn -> check_and_refresh(integration_id, user_id, config) end,
        mode: :blocking
      )
    end
  end

  defp check_and_refresh(integration_id, user_id, config) do
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, fresh} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(fresh)

        if token_still_valid?(decrypted.token_expires_at) do
          {:ok, decrypted.access_token}
        else
          perform_refresh(config)
        end

      {:error, :not_found} ->
        perform_refresh(config)
    end
  end

  defp token_still_valid?(nil), do: false

  defp token_still_valid?(expires_at) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 300, :second)) == :gt
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
    attrs = %{
      access_token: refreshed.access_token,
      refresh_token: refreshed.refresh_token || refreshed.access_token,
      token_expires_at: refreshed.expires_at
    }

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

  defp create_scheduled_meeting(token, start_time, end_time, config) do
    duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
    payload = build_meeting_payload(start_time, duration, config)

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@api_base_url}/users/me/meetings"

    case http_client().request(:post, url, Jason.encode!(payload), headers, []) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        parse_meeting_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp patch_scheduled_meeting(token, room_id, start_time, end_time, config) do
    duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
    payload = build_meeting_payload(start_time, duration, config)

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@api_base_url}/meetings/#{room_id}"

    case http_client().request(:patch, url, Jason.encode!(payload), headers, []) do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: 404, body: body}} ->
        Logger.warning("Zoom meeting no longer exists on reschedule",
          room_id: room_id,
          body: inspect(body)
        )

        {:error, :meeting_not_found}

      {:ok, %Req.Response{status: 401, body: body}} ->
        # Token may have been server-side revoked. Attempt one forced refresh
        # and retry. If refresh fails or the retry also returns 401, flag the
        # integration for reauthentication.
        handle_patch_401(token, room_id, start_time, end_time, config, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp handle_patch_401(_token, room_id, start_time, end_time, config, _body) do
    case refresh_and_update_token(config) do
      {:ok, fresh_token} ->
        duration = max(div(DateTime.diff(end_time, start_time, :second), 60), 15)
        payload = build_meeting_payload(start_time, duration, config)

        headers = [
          {"Authorization", "Bearer #{fresh_token}"},
          {"Content-Type", "application/json"}
        ]

        url = "#{@api_base_url}/meetings/#{room_id}"

        case http_client().request(:patch, url, Jason.encode!(payload), headers, []) do
          {:ok, %Req.Response{status: 204}} ->
            :ok

          {:ok, %Req.Response{status: 401, body: body}} ->
            # Refresh succeeded but Zoom still rejects — token is revoked.
            flag_revoked_token(config)
            decode_and_format_error(401, body)

          {:ok, %Req.Response{status: status, body: body}} ->
            decode_and_format_error(status, body)

          {:error, reason} ->
            {:error, "Network error: #{inspect(reason)}"}
        end

      {:error, _reason} ->
        # Refresh itself failed — credentials are no longer usable.
        flag_revoked_token(config)
        {:error, "Zoom token refresh failed after 401. Please reconnect your Zoom account."}
    end
  end

  defp delete_scheduled_meeting(token, room_id, config) do
    headers = [{"Authorization", "Bearer #{token}"}]
    url = "#{@api_base_url}/meetings/#{room_id}"

    case http_client().request(:delete, url, "", headers, []) do
      {:ok, %Req.Response{status: status}} when status in [204, 200] ->
        :ok

      # Zoom returns 404 when the meeting is already gone — treat as success
      # so cancellation is idempotent.
      {:ok, %Req.Response{status: 404}} ->
        Logger.info("Zoom meeting already deleted", room_id: room_id)
        :ok

      {:ok, %Req.Response{status: 401, body: body}} ->
        # Token may have been server-side revoked. Attempt one forced refresh
        # and retry. If refresh fails or the retry also returns 401, flag the
        # integration for reauthentication.
        handle_delete_401(token, room_id, config, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_and_format_error(status, body)

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp handle_delete_401(_token, room_id, config, _body) do
    case refresh_and_update_token(config) do
      {:ok, fresh_token} ->
        headers = [{"Authorization", "Bearer #{fresh_token}"}]
        url = "#{@api_base_url}/meetings/#{room_id}"

        case http_client().request(:delete, url, "", headers, []) do
          {:ok, %Req.Response{status: status}} when status in [204, 200] ->
            :ok

          {:ok, %Req.Response{status: 404}} ->
            Logger.info("Zoom meeting already deleted", room_id: room_id)
            :ok

          {:ok, %Req.Response{status: 401, body: body}} ->
            # Refresh succeeded but Zoom still rejects — token is revoked.
            flag_revoked_token(config)
            decode_and_format_error(401, body)

          {:ok, %Req.Response{status: status, body: body}} ->
            decode_and_format_error(status, body)

          {:error, reason} ->
            {:error, "Network error: #{inspect(reason)}"}
        end

      {:error, _reason} ->
        # Refresh itself failed — credentials are no longer usable.
        flag_revoked_token(config)
        {:error, "Zoom token refresh failed after 401. Please reconnect your Zoom account."}
    end
  end

  # Flags the integration as needing reauthentication after a 401 that survived
  # a forced token refresh — this indicates server-side revocation at zoom.us.
  # TODO: once needs_reauth is wired to a user-visible reconnect prompt for video
  # integrations (tracking issue: zoom reauth UX), surface this in the dashboard.
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

  defp get_meeting_times(config) do
    with {:ok, start_time} <- resolve_start_time(Map.get(config, :meeting_start_time)),
         {:ok, end_time} <- resolve_end_time(Map.get(config, :meeting_end_time), start_time) do
      {:ok, {start_time, end_time}}
    end
  end

  defp resolve_start_time(nil), do: {:ok, DateTime.add(DateTime.utc_now(), 3600, :second)}
  defp resolve_start_time(dt) when is_binary(dt), do: parse_iso8601(dt)
  defp resolve_start_time(%DateTime{} = dt), do: {:ok, dt}

  defp resolve_end_time(nil, start_time), do: {:ok, DateTime.add(start_time, 1800, :second)}
  defp resolve_end_time(dt, _start_time) when is_binary(dt), do: parse_iso8601(dt)
  defp resolve_end_time(%DateTime{} = dt, _start_time), do: {:ok, dt}

  defp parse_iso8601(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, reason} -> {:error, "Invalid datetime: #{inspect(dt)} (#{reason})"}
    end
  end

  defp build_meeting_payload(start_time, duration_minutes, config) do
    %{
      topic: Map.get(config, :meeting_topic, "Scheduled Meeting"),
      type: 2,
      start_time: DateTime.to_iso8601(start_time),
      duration: duration_minutes,
      timezone: "UTC",
      settings: %{
        join_before_host: false,
        waiting_room: true,
        mute_upon_entry: true
      }
    }
  end

  defp parse_meeting_response(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => _id, "join_url" => _url} = meeting} -> {:ok, meeting}
      {:ok, _other} -> {:error, "Zoom response missing id or join_url"}
      {:error, _reason} -> {:error, "Invalid JSON in Zoom response"}
    end
  end

  defp decode_and_format_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message, "code" => code}} ->
        {:error, "Zoom API error (#{status}): code #{code} - #{message}"}

      _other ->
        {:error, "Zoom API error (#{status}): #{body}"}
    end
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end

  defp zoom_oauth_helper do
    Application.get_env(:tymeslot, :zoom_oauth_helper, ZoomOAuthHelper)
  end
end
