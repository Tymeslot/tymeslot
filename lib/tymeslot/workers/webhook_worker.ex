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

  alias Tymeslot.DatabaseQueries.{MeetingQueries, WebhookQueries}
  alias Tymeslot.DatabaseSchemas.WebhookSchema
  alias Tymeslot.Features
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.PayloadBuilder

  # 10 second timeout for webhook delivery
  @delivery_timeout_ms 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "webhook_id" => webhook_id,
          "event_type" => event_type,
          "meeting_id" => meeting_id
        },
        attempt: attempt
      }) do
    feature = :automations_allowed

    with {:ok, webhook} <- WebhookQueries.get_webhook(webhook_id),
         :ok <- check_feature_access(webhook.user_id, webhook_id, event_type, feature),
         {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         {:ok, _delivery} <- deliver_webhook(webhook, event_type, meeting, attempt) do
      # Record success
      WebhookQueries.record_success(webhook, DateTime.utc_now())
      :ok
    else
      {:error, :not_found} ->
        Logger.warning("Webhook or meeting not found",
          webhook_id: webhook_id,
          meeting_id: meeting_id
        )

        {:discard, "Webhook or meeting not found"}

      {:error, :disabled} ->
        Logger.info("Webhook is disabled, discarding job", webhook_id: webhook_id)
        {:discard, "Webhook is disabled"}

      {:error, :insufficient_plan} ->
        Logger.info("Webhook delivery blocked - insufficient plan",
          webhook_id: webhook_id,
          event_type: event_type
        )

        {:discard, "Insufficient plan"}

      {:error, :feature_access_checker_failed} ->
        Logger.warning("Webhook delivery delayed - feature access check failed",
          webhook_id: webhook_id,
          event_type: event_type
        )

        {:error, :feature_access_checker_failed}

      {:error, reason} = error ->
        Logger.warning("Webhook delivery failed",
          webhook_id: webhook_id,
          event_type: event_type,
          attempt: attempt,
          reason: inspect(reason)
        )

        # Note: failure is already recorded in log_and_update_status
        # to avoid double-counting on retries

        error
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("WebhookWorker job missing required parameters",
      args: inspect(args)
    )

    {:discard, "Missing required parameters"}
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
          reason: inspect(reason)
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
      case WebhookSchema.validate_url_format(webhook.url) do
        :ok ->
          do_deliver_webhook(webhook, event_type, meeting, attempt)

        {:error, reason} ->
          handle_ssrf_blocked(webhook, event_type, meeting, attempt, reason)
      end
    else
      {:error, :disabled}
    end
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

    # Send HTTP request
    headers = Webhooks.build_headers(payload, webhook.webhook_token)
    result = perform_http_request(webhook.url, payload, headers)

    # Log delivery and update webhook status
    log_and_update_status(webhook, event_type, meeting, payload, attempt, result)
  end

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

    {:ok, delivery} = WebhookQueries.create_delivery(delivery_attrs)

    # Update webhook status (success/failure)
    # We only record success/failure on the first attempt or if it's a success
    # to avoid double-counting failures if Oban retries.
    case result do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        WebhookQueries.record_success(webhook)
        {:ok, delivery}

      {:ok, status, _body} ->
        if attempt == 1, do: WebhookQueries.record_failure(webhook, "HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        if attempt == 1, do: WebhookQueries.record_failure(webhook, to_string(reason))
        {:error, reason}
    end
  end

  defp perform_http_request(url, payload, headers) do
    case http_client().post(url, Jason.encode!(payload), headers,
           receive_timeout: @delivery_timeout_ms
         ) do
      {:ok, %{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, %{reason: reason}} ->
        {:error, inspect(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp handle_ssrf_blocked(webhook, event_type, meeting, attempt, reason) do
    Logger.warning("Webhook delivery blocked by SSRF protection",
      webhook_id: webhook.id,
      url: webhook.url,
      reason: reason
    )

    # SSRF block should also count as a failure to eventually disable the webhook
    if attempt == 1, do: WebhookQueries.record_failure(webhook, "SSRF Blocked: #{reason}")

    # Create a delivery log for the blocked attempt
    {:ok, _delivery} =
      WebhookQueries.create_delivery(%{
        webhook_id: webhook.id,
        event_type: event_type,
        meeting_id: meeting.id,
        payload: %{},
        attempt_count: attempt,
        error_message: "Blocked by SSRF protection: #{reason}"
      })

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
