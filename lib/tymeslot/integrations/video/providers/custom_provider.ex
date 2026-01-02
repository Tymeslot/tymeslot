defmodule Tymeslot.Integrations.Video.Providers.CustomProvider do
  @moduledoc """
  Custom video conferencing provider implementation.

  Allows users to provide their own video meeting URLs from any platform.
  This provider simply stores and serves the user-provided URL without any API integration.
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger

  @behaviour ProviderBehaviour

  @impl true
  def create_meeting_room(config) do
    Logger.info("Creating custom video meeting room")

    case Map.get(config, :custom_meeting_url) do
      nil ->
        {:error, "Custom meeting URL is required"}

      "" ->
        {:error, "Custom meeting URL cannot be empty"}

      url ->
        if valid_url?(url) do
          room_data = %{
            room_id: generate_room_id(url),
            meeting_url: url,
            provider_data: %{
              original_url: url,
              created_at: DateTime.utc_now()
            }
          }

          Logger.info("Successfully created custom video meeting with URL: #{mask_url(url)}")
          {:ok, room_data}
        else
          {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
        end
    end
  end

  defp mask_url(url) when is_binary(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}/..."
  end

  defp mask_url(_), do: "..."

  @impl true
  def create_join_url(room_data, _participant_name, _participant_email, _role, _meeting_time) do
    {:ok, room_data.meeting_url}
  end

  @impl true
  def extract_room_id(meeting_url), do: generate_room_id(meeting_url)

  @impl true
  def valid_meeting_url?(meeting_url), do: valid_url?(meeting_url)

  @impl true
  def test_connection(config) do
    case Map.get(config, :custom_meeting_url) do
      nil ->
        {:error, "No custom meeting URL provided"}

      "" ->
        {:error, "Custom meeting URL cannot be empty"}

      url ->
        with :ok <- assert_http_or_https(url),
             :ok <- assert_public_host(url),
             {:ok, status} <- check_reachable(url) do
          {:ok, "URL is reachable (HTTP #{status})"}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def provider_type, do: :custom

  @impl true
  def display_name, do: "Custom Video Link"

  @impl true
  def config_schema do
    %{
      custom_meeting_url: %{
        type: :string,
        required: true,
        label: "Meeting URL",
        help_text:
          "Enter the complete video meeting URL (e.g., https://meet.example.com/room123)",
        placeholder: "https://meet.example.com/room123"
      }
    }
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, :custom_meeting_url) do
      nil ->
        {:error, "Custom meeting URL is required"}

      "" ->
        {:error, "Custom meeting URL cannot be empty"}

      url ->
        if valid_url?(url),
          do: :ok,
          else: {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
    end
  end

  @impl true
  def capabilities do
    %{
      supports_instant_meetings: true,
      supports_scheduled_meetings: true,
      supports_recurring_meetings: true,
      supports_waiting_room: false,
      supports_recording: false,
      supports_dial_in: false,
      max_participants: nil,
      requires_account: false,
      supports_custom_branding: true,
      supports_breakout_rooms: false,
      supports_screen_sharing: false,
      supports_chat: false,
      requires_work_account: false,
      is_custom_provider: true
    }
  end

  @impl true
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl true
  def generate_meeting_metadata(room_data) do
    %{
      provider: "custom",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url,
      custom_url: Map.get(room_data.provider_data, "original_url")
    }
  end

  # Private helpers
  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_url?(_), do: false

  defp generate_room_id(url) do
    :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp assert_http_or_https(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] do
      :ok
    else
      {:error, "Invalid URL scheme. Only http and https are supported"}
    end
  end

  defp assert_public_host(url) do
    uri = URI.parse(url)
    host = uri.host

    with true <- is_binary(host) and host != "",
         {:ok, ip} <- :inet.getaddr(String.to_charlist(host), :inet),
         false <- private_or_loopback_ip?(ip) do
      :ok
    else
      false -> {:error, "Invalid host in URL"}
      {:error, _} -> {:error, "Could not resolve host: #{host}"}
      true -> {:error, "URL resolves to a private or loopback address"}
    end
  end

  defp private_or_loopback_ip?({127, _, _, _}), do: true
  defp private_or_loopback_ip?({10, _, _, _}), do: true
  defp private_or_loopback_ip?({192, 168, _, _}), do: true
  defp private_or_loopback_ip?({169, 254, _, _}), do: true
  defp private_or_loopback_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_or_loopback_ip?(_), do: false

  defp check_reachable(url) do
    opts = [
      timeout: 3_000,
      recv_timeout: 3_000,
      follow_redirect: true,
      max_redirect: 3,
      ssl: [{:versions, [:"tlsv1.2", :"tlsv1.3"]}]
    ]

    case HTTPoison.head(url, [], opts) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..399 ->
        {:ok, status}

      {:ok, %HTTPoison.Response{status_code: 405}} ->
        do_get(url, opts)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "URL responded with HTTP #{status}"}

      {:error, _} ->
        do_get(url, opts)
    end
  end

  defp do_get(url, opts) do
    case HTTPoison.get(url, [], opts) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..399 ->
        {:ok, status}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "URL responded with HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, "Connection timeout while reaching the URL"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Failed to reach URL: #{inspect(reason)}"}
    end
  end
end
