defmodule Tymeslot.Integrations.Video.Providers.CustomProvider do
  @moduledoc """
  Custom video conferencing provider implementation.

  Allows users to provide their own video meeting URLs from any platform.
  This provider simply stores and serves the user-provided URL without any API integration.

  ## Template Variables

  URLs can include the `{{meeting_id}}` template variable, which will be replaced
  with a secure hash of the meeting ID during room creation. This allows users to
  create unique meeting rooms per booking while using their own video platform.

  ### Examples

      # Static URL (same room for all meetings)
      "https://meet.example.com/my-permanent-room"

      # Template URL (unique room per meeting)
      "https://jitsi.example.org/{{meeting_id}}"
      # Becomes: "https://jitsi.example.org/a1b2c3d4e5f67890"

  ### Security & Collision Resistance

  - Template variables are replaced with 16-character SHA256 hashes
  - Hashing prevents URL injection attacks (query params, path traversal, fragments)
  - 50% collision probability at ~4.3 billion meetings (birthday paradox)
  - 1% collision probability at ~430 million meetings
  - Deterministic hashing ensures idempotency (same meeting_id → same URL)

  ### Requirements

  - Template URLs require a valid `meeting_id` in the config
  - Missing `meeting_id` for template URLs will return an error
  - Processed URLs must not exceed 255 characters (database constraint)

  ## URL Validation

  All URLs (static and template) must:
  - Use HTTP or HTTPS scheme
  - Have a valid, resolvable host
  - Not point to private or loopback addresses (in test_connection only)
  - Be reachable (in test_connection only)
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.TemplateConfig

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
        with {:ok, processed_url} <- process_template(url, config),
             :ok <- validate_url_length(processed_url),
             true <- valid_url?(processed_url) do
          room_data = %{
            room_id: generate_room_id(processed_url),
            meeting_url: processed_url,
            provider_data: %{
              original_url: url,
              processed_url: processed_url,
              created_at: DateTime.utc_now()
            }
          }

          # Emit telemetry for observability
          :telemetry.execute(
            [:tymeslot, :video, :custom_provider, :meeting_created],
            %{processed_url_length: String.length(processed_url)},
            %{
              template_used: String.contains?(url, TemplateConfig.template_variable()),
              original_url_length: String.length(url)
            }
          )

          Logger.info(
            "Successfully created custom video meeting with URL: #{mask_url(processed_url)}"
          )

          {:ok, room_data}
        else
          {:error, reason} -> {:error, reason}
          false -> {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
        end
    end
  end

  defp process_template(url, config) do
    if String.contains?(url, TemplateConfig.template_variable()) do
      # Validate template position before processing
      with :ok <- validate_template_position(url) do
        process_template_with_meeting_id(url, config)
      end
    else
      # Static URL - no template processing needed
      {:ok, url}
    end
  end

  defp validate_template_position(url) do
    uri = URI.parse(url)

    if uri.fragment && String.contains?(uri.fragment, TemplateConfig.template_variable()) do
      {:error,
       "Template variable cannot be used in URL fragment (#). Fragments are not sent to the server, so all meetings would use the same room. Use the template in the path instead: https://example.com/{{meeting_id}}"}
    else
      :ok
    end
  end

  defp process_template_with_meeting_id(url, config) do
    # Template URL - meeting_id is required
    case Map.get(config, :meeting_id) do
      meeting_id when is_binary(meeting_id) and byte_size(meeting_id) > 0 ->
        hashed_id = hash_meeting_id(meeting_id)
        processed = String.replace(url, TemplateConfig.template_variable(), hashed_id)

        Logger.debug("Processing URL template: #{mask_url(url)} -> #{mask_url(processed)}")

        {:ok, processed}

      meeting_id when not is_nil(meeting_id) ->
        # Convert non-string meeting_id to string and check if non-empty
        string_id = to_string(meeting_id)

        if byte_size(string_id) > 0 do
          hashed_id = hash_meeting_id(string_id)
          processed = String.replace(url, TemplateConfig.template_variable(), hashed_id)

          Logger.debug("Processing URL template: #{mask_url(url)} -> #{mask_url(processed)}")

          {:ok, processed}
        else
          Logger.error("Template URL requires non-empty meeting_id", url: mask_url(url))
          {:error, "meeting_id is required for template URLs but was empty"}
        end

      nil ->
        Logger.error("Template URL requires meeting_id", url: mask_url(url))
        {:error, "meeting_id is required for template URLs"}
    end
  end

  defp hash_meeting_id(meeting_id) do
    :crypto.hash(:sha256, to_string(meeting_id))
    |> Base.encode16(case: :lower)
    |> String.slice(0, TemplateConfig.hash_length())
  end

  defp validate_url_length(url) do
    url_length = String.length(url)
    max_length = TemplateConfig.max_url_length()

    if url_length <= max_length do
      :ok
    else
      {:error,
       "Processed URL exceeds maximum length of #{max_length} characters (got #{url_length})"}
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
        # Validate template position first
        with :ok <- validate_template_position(url) do
          # Replace template variables with sample values for testing
          test_url =
            String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

          with :ok <- assert_http_or_https(test_url),
               :ok <- assert_public_host(test_url),
               {:ok, status} <- check_reachable(test_url) do
            {:ok, "URL is reachable (HTTP #{status})"}
          else
            {:error, reason} -> {:error, reason}
          end
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
        # Validate template position first
        with :ok <- validate_template_position(url) do
          # Test with a sample meeting_id to validate template URLs
          test_url =
            String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

          if valid_url?(test_url),
            do: :ok,
            else: {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
        end
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
      receive_timeout: 3_000,
      connect_options: [timeout: 3_000],
      redirect: true,
      max_redirects: 3
    ]

    case http_client().head(url, [], opts) do
      {:ok, %{status: status}} when status in 200..399 ->
        {:ok, status}

      {:ok, %{status: 405}} ->
        do_get(url, opts)

      {:ok, %{status: status}} ->
        {:error, "URL responded with HTTP #{status}"}

      {:error, _} ->
        do_get(url, opts)
    end
  end

  defp do_get(url, opts) do
    case http_client().get(url, [], opts) do
      {:ok, %{status: status}} when status in 200..399 ->
        {:ok, status}

      {:ok, %{status: status}} ->
        {:error, "URL responded with HTTP #{status}"}

      {:error, exception} when is_exception(exception) ->
        case exception do
          %Mint.TransportError{reason: :timeout} ->
            {:error, "Connection timeout while reaching the URL"}

          %Req.TransportError{reason: :timeout} ->
            {:error, "Connection timeout while reaching the URL"}

          _ ->
            {:error, "Failed to reach URL: #{Exception.message(exception)}"}
        end

      {:error, reason} ->
        {:error, "Failed to reach URL: #{inspect(reason)}"}
    end
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
