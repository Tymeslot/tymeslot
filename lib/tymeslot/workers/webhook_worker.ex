defmodule Tymeslot.Workers.WebhookWorker do
  @moduledoc """
  Oban worker for delivering webhook notifications.

  Handles:
  - HTTP POST delivery with timeout protection
  - HMAC signature generation
  - Exponential backoff retry logic
  - Circuit breaker (auto-disable after consecutive failures)
  - Delivery logging and metrics
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    priority: 2

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.{DnsResolution, UrlValidation}
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.{PayloadBuilder, WebhookQueries, WebhookSchema}

  # 10 second timeout for webhook delivery
  @delivery_timeout_ms 10_000
  # Max redirect hops we will follow. Each hop is independently re-validated
  # by check_ssrf/1 so that a public host cannot bounce us to loopback or
  # link-local ranges.
  @max_redirects 5

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "webhook_id" => webhook_id,
            "event_type" => event_type,
            "meeting_id" => meeting_id
          },
          attempt: attempt
        } = job
      ) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    feature = :automations_allowed

    with {:ok, webhook} <- WebhookQueries.get_webhook(webhook_id),
         :ok = Logger.metadata(user_id: webhook.user_id),
         :ok <- check_feature_access(webhook.user_id, webhook_id, event_type, feature),
         {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         {:ok, _delivery} <- deliver_webhook(webhook, event_type, meeting, attempt) do
      :ok
    else
      error -> handle_delivery_error(error, webhook_id, meeting_id, event_type)
    end
  end

  def perform(%Oban.Job{id: job_id, args: args, attempt: attempt}) do
    Logger.metadata(job_id: job_id, attempt: attempt)

    Logger.error("WebhookWorker job missing required parameters",
      arg_keys: Map.keys(args)
    )

    {:discard, "Missing required parameters"}
  end

  # Translate every known error from the `with` pipeline in `perform/1` into the
  # correct Oban result — either `{:discard, reason}` for deterministic failures
  # that should never be retried, or `{:error, reason}` for transient ones.
  defp handle_delivery_error({:error, :not_found}, webhook_id, meeting_id, _event_type) do
    Logger.warning("Webhook or meeting not found",
      webhook_id: webhook_id,
      meeting_id: meeting_id
    )

    {:discard, "Webhook or meeting not found"}
  end

  defp handle_delivery_error({:error, :disabled}, webhook_id, _meeting_id, _event_type) do
    Logger.info("Webhook is disabled, discarding job", webhook_id: webhook_id)
    {:discard, "Webhook is disabled"}
  end

  defp handle_delivery_error({:error, :insufficient_plan}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery blocked - insufficient plan",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, "Insufficient plan"}
  end

  defp handle_delivery_error(
         {:error, :feature_access_checker_failed},
         webhook_id,
         _meeting_id,
         event_type
       ) do
    Logger.warning("Webhook delivery delayed - feature access check failed",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:error, :feature_access_checker_failed}
  end

  defp handle_delivery_error({:error, :blocked_by_ssrf}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery discarded - SSRF blocked",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, :blocked_by_ssrf}
  end

  defp handle_delivery_error({:error, :blocked_redirect}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery discarded - redirect blocked",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, :blocked_redirect}
  end

  defp handle_delivery_error({:error, :too_many_redirects}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery discarded - too many redirects",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, :too_many_redirects}
  end

  defp handle_delivery_error(
         {:error, :redirect_missing_location},
         webhook_id,
         _meeting_id,
         event_type
       ) do
    Logger.info("Webhook delivery discarded - redirect missing Location header",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, :redirect_missing_location}
  end

  defp handle_delivery_error({:error, reason} = error, webhook_id, _meeting_id, event_type) do
    Logger.warning("Webhook delivery failed",
      webhook_id: webhook_id,
      event_type: event_type,
      reason: reason
    )

    # Note: failure is already recorded in log_and_update_status
    # to avoid double-counting on retries
    error
  end

  @doc """
  Schedules a webhook delivery via Oban.
  """
  @spec schedule_delivery(integer(), String.t(), binary()) :: :ok | {:error, term()}
  def schedule_delivery(webhook_id, event_type, meeting_id) do
    result =
      %{
        "webhook_id" => webhook_id,
        "event_type" => event_type,
        "meeting_id" => meeting_id
      }
      |> new(
        queue: :webhooks,
        priority: 2,
        unique: [
          # 5 minute uniqueness window
          period: 300,
          fields: [:args],
          keys: [:webhook_id, :event_type, :meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.debug("Webhook delivery job scheduled",
          webhook_id: webhook_id,
          event_type: event_type
        )

        :ok

      {:error, %Ecto.Changeset{errors: [unique: _details]}} ->
        Logger.debug("Webhook delivery job already exists",
          webhook_id: webhook_id,
          event_type: event_type
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type,
          reason: reason
        )

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s
    min(round(:math.pow(2, attempt - 1)), 16)
  end

  # Private functions

  defp deliver_webhook(%WebhookSchema{} = webhook, event_type, meeting, attempt) do
    if WebhookSchema.should_be_active?(webhook) do
      case check_ssrf(webhook.url) do
        :ok ->
          do_deliver_webhook(webhook, event_type, meeting, attempt)

        {:error, reason} ->
          handle_ssrf_blocked(webhook, event_type, meeting, attempt, reason)
      end
    else
      {:error, :disabled}
    end
  end

  defp check_ssrf(url) do
    if production?() do
      with :ok <-
             UrlValidation.validate_http_url(url,
               block_private_ips: true,
               enforce_https: true
             ) do
        dns_resolver().check_private_ip(url, [])
      end
    else
      UrlValidation.validate_http_url(url)
    end
  end

  @spec dns_resolver() :: module()
  defp dns_resolver do
    Application.get_env(:tymeslot, :dns_resolver_module, DnsResolution)
  end

  defp production? do
    Application.get_env(:tymeslot, :environment) == :prod
  end

  @spec check_feature_access(integer(), integer(), String.t(), atom()) ::
          :ok | {:error, :insufficient_plan | :feature_access_checker_failed}
  defp check_feature_access(user_id, webhook_id, event_type, feature) do
    case Features.check_access(user_id, feature) do
      :ok ->
        :ok

      {:error, :insufficient_plan} = error ->
        Logger.info("Feature access denied for webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type,
          feature: feature
        )

        error

      {:error, :feature_access_checker_failed} = error ->
        Logger.warning("Feature access check failed for webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type,
          feature: feature
        )

        error
    end
  end

  defp do_deliver_webhook(webhook, event_type, meeting, attempt) do
    # Decrypt token
    webhook = WebhookSchema.decrypt_token(webhook)

    # Build payload
    payload = PayloadBuilder.build_payload(event_type, meeting, to_string(webhook.id))

    # Send HTTP request, validating SSRF on each redirect hop
    headers = Webhooks.build_headers(payload, webhook.webhook_token)
    encoded_payload = Jason.encode!(payload)
    result = deliver_with_redirects(webhook.url, encoded_payload, headers, @max_redirects)

    # Log delivery and update webhook status
    log_and_update_status(webhook, event_type, meeting, payload, attempt, result)
  end

  # Manually follow redirects with `check_ssrf/1` on every hop. Req's built-in
  # redirect step is disabled (`redirect: false`) so a 3xx from a public host
  # cannot redirect us to 127.0.0.1, 169.254.169.254, or any other private
  # range that the initial validation rejected.
  defp deliver_with_redirects(_url, _body, _headers, 0) do
    Logger.warning("Webhook delivery exceeded max redirects")
    {:error, :too_many_redirects}
  end

  defp deliver_with_redirects(url, body, headers, redirects_remaining) do
    case perform_http_request(url, body, headers) do
      {:ok, status, _body, response_headers} when status in 300..399 ->
        follow_redirect(url, body, headers, response_headers, redirects_remaining)

      {:ok, status, response_body, _headers} ->
        {:ok, status, response_body}

      {:error, _reason} = error ->
        error
    end
  end

  defp follow_redirect(from_url, body, headers, response_headers, redirects_remaining) do
    with {:ok, next_url} <- extract_location(response_headers, from_url),
         :ok <- check_ssrf(next_url) do
      safe_headers = sanitise_headers_for_redirect(headers, from_url, next_url)
      deliver_with_redirects(next_url, body, safe_headers, redirects_remaining - 1)
    else
      :error ->
        Logger.warning("Webhook redirect missing Location header", from_url: from_url)
        {:error, :redirect_missing_location}

      {:error, reason} ->
        Logger.warning("Webhook redirect blocked by SSRF protection",
          from_url: from_url,
          reason: reason
        )

        {:error, :blocked_redirect}
    end
  end

  # Strip sensitive request headers when a redirect crosses origins.
  # "Origin" here means scheme + host + port — a redirect to the same host on
  # the same port is considered same-origin and the token is preserved so that
  # receivers that legitimately redirect within their own host continue to work.
  defp sanitise_headers_for_redirect(headers, from_url, next_url) do
    if same_origin?(from_url, next_url) do
      headers
    else
      Enum.reject(headers, fn
        {"X-Tymeslot-Token", _value} -> true
        {"Authorization", _value} -> true
        _other -> false
      end)
    end
  end

  defp same_origin?(url_a, url_b) do
    a = URI.parse(url_a)
    b = URI.parse(url_b)

    a.scheme == b.scheme and
      String.downcase(a.host || "") == String.downcase(b.host || "") and
      normalise_port(a.scheme, a.port) == normalise_port(b.scheme, b.port)
  end

  # Returns the effective port, substituting the default for scheme when nil.
  defp normalise_port("https", nil), do: 443
  defp normalise_port("http", nil), do: 80
  defp normalise_port(_scheme, port), do: port

  defp extract_location(response_headers, from_url) do
    case location_value(response_headers) do
      nil ->
        :error

      raw_location ->
        resolved =
          case URI.parse(raw_location) do
            %URI{scheme: scheme, host: host} = uri
            when is_binary(scheme) and is_binary(host) and host != "" ->
              # Fully-qualified absolute URL (e.g. https://other.example.com/path)
              URI.to_string(uri)

            %URI{scheme: nil, host: host} = uri
            when is_binary(host) and host != "" ->
              # Protocol-relative URL (e.g. //other.example.com/path) — inherit
              # the scheme from the originating request rather than merging as a
              # relative reference, which would retain the original path.
              base_scheme = URI.parse(from_url).scheme || "https"
              URI.to_string(%{uri | scheme: base_scheme})

            _relative ->
              from_url |> URI.merge(raw_location) |> URI.to_string()
          end

        {:ok, resolved}
    end
  end

  defp location_value(headers) when is_map(headers) do
    # Req 0.5+ returns headers as a map of lowercase string → [value] list.
    case Map.get(headers, "location") do
      [value | _rest] when is_binary(value) -> value
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp location_value(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) or is_atom(key) ->
        if String.downcase(to_string(key)) == "location", do: to_string(value)

      _other ->
        nil
    end)
  end

  defp location_value(_headers), do: nil

  defp log_and_update_status(webhook, event_type, meeting, payload, attempt, result) do
    # Create delivery log entry
    delivery_attrs = %{
      webhook_id: webhook.id,
      event_type: event_type,
      meeting_id: meeting.id,
      payload: payload,
      attempt_count: attempt
    }

    delivery_attrs =
      case result do
        {:ok, status, response_body} ->
          Map.merge(delivery_attrs, %{
            response_status: status,
            response_body: truncate_response(response_body),
            delivered_at: DateTime.utc_now()
          })

        {:error, error_message} ->
          Map.put(delivery_attrs, :error_message, truncate_response(error_message))
      end

    case WebhookQueries.create_delivery(delivery_attrs) do
      {:ok, delivery} ->
        # Update webhook status (success/failure)
        # We only record success/failure on the first attempt or if it's a success
        # to avoid double-counting failures if Oban retries.
        case result do
          {:ok, status, _body} when status >= 200 and status < 300 ->
            WebhookQueries.record_success(webhook)
            {:ok, delivery}

          {:ok, status, _body} ->
            if attempt == 1, do: Webhooks.record_delivery_failure(webhook, "HTTP #{status}")
            {:error, {:http_error, status}}

          {:error, reason} ->
            if attempt == 1, do: Webhooks.record_delivery_failure(webhook, to_string(reason))
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to create webhook delivery log", error: inspect(reason))
        {:error, :delivery_log_failed}
    end
  end

  defp perform_http_request(url, body, headers) do
    case http_client().post(url, body, headers,
           receive_timeout: @delivery_timeout_ms,
           redirect: false
         ) do
      {:ok, response} ->
        {:ok, Map.get(response, :status), Map.get(response, :body),
         Map.get(response, :headers, %{})}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_ssrf_blocked(webhook, event_type, meeting, attempt, reason) do
    Logger.warning("Webhook delivery blocked by SSRF protection",
      webhook_id: webhook.id,
      url: webhook.url,
      reason: reason
    )

    # SSRF block should also count as a failure to eventually disable the webhook
    if attempt == 1, do: Webhooks.record_delivery_failure(webhook, "SSRF Blocked: #{reason}")

    # Create a delivery log for the blocked attempt
    case WebhookQueries.create_delivery(%{
           webhook_id: webhook.id,
           event_type: event_type,
           meeting_id: meeting.id,
           payload: %{},
           attempt_count: attempt,
           error_message: "Blocked by SSRF protection: #{reason}"
         }) do
      {:ok, _delivery} -> :ok
      {:error, err} -> Logger.warning("Failed to create SSRF delivery log", error: inspect(err))
    end

    {:error, :blocked_by_ssrf}
  end

  # Truncate response to prevent database bloat and ensure UTF-8 compatibility
  @spec truncate_response(String.t() | term() | nil) :: String.t() | nil
  defp truncate_response(nil), do: nil

  defp truncate_response(response) when is_binary(response) do
    # Ensure the string is valid UTF-8 to prevent Ecto errors
    safe_response =
      if String.printable?(response) do
        response
      else
        # If not printable (contains binary data), inspect it
        inspect(response, binaries: :as_strings, limit: 5000)
      end

    if String.length(safe_response) > 5000 do
      String.slice(safe_response, 0, 5000) <> "... (truncated)"
    else
      safe_response
    end
  end

  defp truncate_response(response), do: truncate_response(inspect(response))

  @spec http_client() :: module()
  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
