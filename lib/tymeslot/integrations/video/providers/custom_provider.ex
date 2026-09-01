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
  - Be reachable (in perform_connection_test only)

  The reachability probe is the only outbound request this provider ever makes:
  a booking hands the URL to the browser rather than fetching it. That probe
  goes through `Tymeslot.Security.SsrfGuard`, so in `:prod` a host resolving to
  a private, loopback, or link-local address is refused unless the operator has
  set `ALLOW_PRIVATE_IPS_FOR_VIDEO` (see `SsrfGuard.allow_private_for_video?/0`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.RedirectLocation
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.TemplateConfig
  alias Tymeslot.Security.SsrfBlockedError
  alias Tymeslot.Security.SsrfGuard

  require Logger

  @behaviour ProviderBehaviour

  @capabilities Capabilities.new!(
                  waiting_room: false,
                  recording: false,
                  dial_in: false,
                  max_participants: nil,
                  breakout_rooms: false,
                  screen_sharing: false,
                  chat: false
                )

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    Logger.info("Creating custom video meeting room")

    case Map.get(config, :custom_meeting_url) do
      url when url in [nil, ""] ->
        {:error, custom_url_required_message()}

      url ->
        with {:ok, processed_url} <- process_template(url, config),
             :ok <- validate_url_length(processed_url),
             true <- valid_url?(processed_url) do
          room_data = %RoomData{
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

          Logger.info("Successfully created custom video meeting",
            url: mask_url(processed_url)
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
       dgettext(
         "dashboard_integrations",
         "Template variable cannot be used in URL fragment (#). Fragments are not sent to the server, so all meetings would use the same room. Use the template in the path instead: https://example.com/{{meeting_id}}"
       )}
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

        Logger.debug("Processing URL template",
          input_url: mask_url(url),
          output_url: mask_url(processed)
        )

        {:ok, processed}

      "" ->
        Logger.error("Template URL requires non-empty meeting_id", url: mask_url(url))
        {:error, "meeting_id is required for template URLs but was empty"}

      meeting_id when is_integer(meeting_id) or is_atom(meeting_id) ->
        # Convert non-string meeting_id to string and check if non-empty
        string_id = to_string(meeting_id)

        if byte_size(string_id) > 0 do
          hashed_id = hash_meeting_id(string_id)
          processed = String.replace(url, TemplateConfig.template_variable(), hashed_id)

          Logger.debug("Processing URL template",
            input_url: mask_url(url),
            output_url: mask_url(processed)
          )

          {:ok, processed}
        else
          Logger.error("Template URL requires non-empty meeting_id", url: mask_url(url))
          {:error, "meeting_id is required for template URLs but was empty"}
        end
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
       dgettext(
         "dashboard_integrations",
         "Processed URL exceeds maximum length of %{max_length} characters (got %{url_length})",
         max_length: max_length,
         url_length: url_length
       )}
    end
  end

  defp mask_url(url) when is_binary(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}/..."
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, _participant_name, _participant_email, _role, _meeting_time) do
    {:ok, room_data.meeting_url}
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url), do: generate_room_id(meeting_url)

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(meeting_url), do: valid_url?(meeting_url)

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    case Map.get(config, :custom_meeting_url) do
      url when url in [nil, ""] ->
        {:error, custom_url_required_message()}

      url ->
        # Validate template position first
        with :ok <- validate_template_position(url) do
          # Replace template variables with sample values for testing
          test_url =
            String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

          with :ok <- assert_http_or_https(test_url),
               {:ok, status} <- check_reachable(test_url) do
            # Shares the msgid the non-2xx branches use: the caller wraps a
            # success in "✓ Custom provider configured - …", so the status
            # line does not have to carry the verdict itself.
            {:ok,
             dgettext("dashboard_integrations", "URL responded with HTTP %{status}",
               status: status
             )}
          else
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :custom

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "Custom Video Link"

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def connection_test_bucket, do: :custom

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def validate_config(config) do
    case Map.get(config, :custom_meeting_url) do
      url when url in [nil, ""] ->
        {:error, custom_url_required_message()}

      url ->
        # Validate template position first
        with :ok <- validate_template_position(url) do
          # Test with a sample meeting_id to validate template URLs
          test_url =
            String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

          if valid_url?(test_url),
            do: :ok,
            else:
              {:error,
               dgettext(
                 "dashboard_integrations",
                 "Invalid URL format. Please provide a valid HTTP/HTTPS URL."
               )}
        end
    end
  end

  defp custom_url_required_message,
    do: dgettext("dashboard_integrations", "Custom meeting URL is required")

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def capabilities, do: @capabilities

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data), do: :ok

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "custom",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url,
      custom_url: Map.get(room_data.provider_data, :original_url)
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def build_config(integration, _decrypted, opts) do
    %{
      custom_meeting_url: integration.custom_meeting_url,
      meeting_id: Keyword.get(opts, :meeting_id)
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def credential_spec do
    %{
      required: [:custom_meeting_url],
      credential_pairs: [],
      url_fields: [:custom_meeting_url]
    }
  end

  # Private helpers
  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_url?(_url), do: false

  defp generate_room_id(url) do
    :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp assert_http_or_https(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_integrations",
         "Invalid URL scheme. Only http and https are supported"
       )}
    end
  end

  # The host is user-supplied, so every hop is classified in its own right.
  # `ssrf_protect: true` hands the private-address decision to `SsrfGuard`,
  # which resolves every A and AAAA record, is gated to `:prod` so a local video
  # container stays reachable in development, and honours the operator's
  # ALLOW_PRIVATE_IPS_FOR_VIDEO opt-out. It also forcibly sets `redirect: false`
  # and validates only the URL it is handed, so letting the client follow
  # redirects itself would leave every hop after the first unchecked: a host
  # that resolves publicly can 302 straight to 127.0.0.1 or the cloud metadata
  # endpoint. Following them here reports status, timeout and
  # connection-refused apart. The ICS feed fetcher has the identical problem
  # and the same shape; `Tymeslot.Infrastructure.RedirectLocation` is the one
  # place both resolve a hop's target, and documents the budget convention
  # this counter follows (`hops_left < 0` refuses, so 3 means three follows).
  @max_redirects 3

  # Each request was previously bounded per-hop only (3s connect + 3s receive),
  # so the worst case grew with every added hop: up to `@max_redirects + 1`
  # hops, two requests each (HEAD then a GET fallback), was ~48s with no
  # overall bound. This caps the whole probe — HEAD, GET fallback and every
  # redirect hop together — at the original single-hop worst case, shrinking
  # each subsequent request's own timeout to whatever budget remains rather
  # than handing out a fresh 3s per hop.
  @overall_budget_ms 12_000

  defp probe_deadline, do: System.monotonic_time(:millisecond) + @overall_budget_ms

  # Built per call rather than as a module attribute: the opt-out is read from
  # application config at runtime, and an attribute would freeze it at compile
  # time. `budget_ms` shrinks the per-request timeout to whatever remains of
  # the overall probe deadline, capped at the original 3s.
  defp probe_opts(budget_ms) do
    per_request_timeout = min(3_000, budget_ms)

    [
      receive_timeout: per_request_timeout,
      connect_options: [timeout: per_request_timeout],
      ssrf_protect: true,
      ssrf_allow_private: SsrfGuard.allow_private_for_video?()
    ]
  end

  defp check_reachable(url), do: check_reachable(url, @max_redirects, probe_deadline())

  defp check_reachable(_url, hops_left, _deadline) when hops_left < 0 do
    {:error, dgettext("dashboard_integrations", "URL redirects too many times")}
  end

  defp check_reachable(url, hops_left, deadline) do
    with {:ok, budget_ms} <- remaining_budget(deadline) do
      case Config.http_client_module().head(url, [], probe_opts(budget_ms)) do
        {:ok, %{status: 405}} ->
          do_get(url, hops_left, deadline)

        {:ok, response} ->
          classify_probe(response, url, hops_left, deadline)

        {:error, %SsrfBlockedError{}} ->
          {:error, blocked_url_message()}

        {:error, _reason} ->
          do_get(url, hops_left, deadline)
      end
    end
  end

  defp do_get(url, hops_left, deadline) do
    with {:ok, budget_ms} <- remaining_budget(deadline) do
      case Config.http_client_module().get(url, [], probe_opts(budget_ms)) do
        {:ok, response} ->
          classify_probe(response, url, hops_left, deadline)

        {:error, %SsrfBlockedError{}} ->
          {:error, blocked_url_message()}

        {:error, exception} when is_exception(exception) ->
          case exception do
            %Mint.TransportError{reason: :timeout} ->
              {:error, url_timeout_message()}

            %Req.TransportError{reason: :timeout} ->
              {:error, url_timeout_message()}

            _network_exception ->
              {:error, unreachable_url_message(Exception.message(exception))}
          end

        {:error, reason} ->
          {:error, unreachable_url_message(inspect(reason))}
      end
    end
  end

  defp remaining_budget(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, url_timeout_message()}
    end
  end

  defp classify_probe(%{status: status} = response, url, hops_left, deadline)
       when status in 300..399 do
    case RedirectLocation.next_url(Map.get(response, :headers, %{}), url) do
      # A 3xx we cannot follow is still a host that answered, so the probe
      # reports the status rather than calling the URL unreachable.
      {:error, _unfollowable} -> {:ok, status}
      {:ok, target} -> check_reachable(target, hops_left - 1, deadline)
    end
  end

  defp classify_probe(%{status: status}, _url, _hops_left, _deadline) when status in 200..299 do
    {:ok, status}
  end

  defp classify_probe(%{status: status}, _url, _hops_left, _deadline) do
    {:error,
     dgettext("dashboard_integrations", "URL responded with HTTP %{status}", status: status)}
  end

  defp blocked_url_message,
    do: dgettext("dashboard_integrations", "URL resolves to a private or loopback address")

  defp url_timeout_message,
    do: dgettext("dashboard_integrations", "Connection timeout while reaching the URL")

  defp unreachable_url_message(reason),
    do: dgettext("dashboard_integrations", "Failed to reach URL: %{reason}", reason: reason)
end
