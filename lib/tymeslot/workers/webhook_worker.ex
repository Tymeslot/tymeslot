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
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Webhooks

  alias Tymeslot.Webhooks.{
    HttpDelivery,
    PayloadBuilder,
    WebhookQueries,
    WebhookSchema
  }

  # The event-defining fields of a meeting, captured at the moment a webhook
  # fires and replayed at delivery time instead of being re-derived. Without
  # this, a `meeting.requested` delivery retried after the host has since
  # approved or declined re-reads the meeting fresh and reports its *current*
  # state under the original event's envelope — the event says one thing and
  # the body says another. Kept to the handful of scalar/datetime fields that
  # actually drive `PayloadBuilder`'s status-dependent sections, rather than
  # snapshotting the whole meeting into the job args.
  @snapshot_fields ~w(
    status cancelled_at cancellation_reason decline_reason
    approval_requested_at approval_deadline_at approval_resolved_at
  )a

  @datetime_snapshot_fields ~w(
    cancelled_at approval_requested_at approval_deadline_at approval_resolved_at
  )a

  @doc """
  Captures the event-defining fields of a meeting for `schedule_delivery/4`.

  Called by the trigger site at the moment the event fires, so a retried
  delivery can replay what that event asserted rather than whatever the
  meeting looks like by the time the retry runs.
  """
  @spec snapshot(MeetingSchema.t()) :: map()
  def snapshot(%MeetingSchema{} = meeting) do
    meeting
    |> Map.take(@snapshot_fields)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), encode_snapshot_field(value)} end)
  end

  defp encode_snapshot_field(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_snapshot_field(value), do: value

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "webhook_id" => webhook_id,
              "event_type" => event_type,
              "meeting_id" => meeting_id
            } = args,
          attempt: attempt
        } = job
      ) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    feature = :automations_allowed

    with {:ok, webhook} <- WebhookQueries.get_webhook(webhook_id),
         :ok = Logger.metadata(user_id: webhook.user_id),
         :ok <- check_feature_access(webhook.user_id, webhook_id, event_type, feature),
         {:ok, meeting} <- fetch_meeting(meeting_id, args["snapshot"]),
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

  # `http_failure/3` already reached a terminal verdict; pass it through rather
  # than letting a `{:discard, _}` fall past every `{:error, _}` clause below.
  defp handle_delivery_error(
         {:discard, _reason} = discard,
         _webhook_id,
         _meeting_id,
         _event_type
       ),
       do: discard

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

  `snapshot`, from `snapshot/1`, is what a retried delivery replays instead of
  re-deriving the meeting's current state; omit it (or pass `nil`) only where
  the event has no status-dependent payload section to protect.
  """
  @spec schedule_delivery(integer(), String.t(), binary(), map() | nil) :: :ok | {:error, term()}
  def schedule_delivery(webhook_id, event_type, meeting_id, snapshot \\ nil) do
    result =
      %{
        "webhook_id" => webhook_id,
        "event_type" => event_type,
        "meeting_id" => meeting_id
      }
      |> maybe_put_snapshot(snapshot)
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

  defp maybe_put_snapshot(args, nil), do: args

  defp maybe_put_snapshot(args, snapshot) when is_map(snapshot),
    do: Map.put(args, "snapshot", snapshot)

  # Loads the meeting fresh (for the data that legitimately changes between
  # attempts, like a guest that responded, or attaches a job-arg snapshot the
  # trigger site captured, so what fired at dispatch time is what gets
  # delivered on every attempt. `snapshot` is `nil` for jobs enqueued before
  # this was threaded through — those keep re-deriving from the live meeting,
  # same as before.
  defp fetch_meeting(meeting_id, snapshot) do
    with {:ok, meeting} <- MeetingQueries.get_meeting_with_guests(meeting_id) do
      {:ok, apply_snapshot(meeting, snapshot)}
    end
  end

  defp apply_snapshot(meeting, nil), do: meeting

  defp apply_snapshot(%MeetingSchema{} = meeting, snapshot) when is_map(snapshot) do
    overrides =
      Enum.map(@snapshot_fields, fn field ->
        {field, snapshot_field_value(snapshot, field, Map.get(meeting, field))}
      end)

    struct(meeting, overrides)
  end

  defp snapshot_field_value(snapshot, field, default) do
    case Map.fetch(snapshot, Atom.to_string(field)) do
      {:ok, value} -> decode_snapshot_field(field, value)
      :error -> default
    end
  end

  defp decode_snapshot_field(_field, nil), do: nil

  defp decode_snapshot_field(field, value) when field in @datetime_snapshot_fields do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  defp decode_snapshot_field(_field, value), do: value

  defp deliver_webhook(%WebhookSchema{} = webhook, event_type, meeting, attempt) do
    if WebhookSchema.should_be_active?(webhook) do
      do_deliver_webhook(webhook, event_type, meeting, attempt)
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
    webhook = WebhookSchema.decrypt_token(webhook)
    payload = PayloadBuilder.build_payload(event_type, meeting, to_string(webhook.id))
    headers = Webhooks.build_headers(payload, webhook.webhook_token)
    encoded_payload = Jason.encode!(payload)
    result = HttpDelivery.post(webhook.url, encoded_payload, headers)

    log_and_update_status(webhook, event_type, meeting, payload, attempt, result)
  end

  defp log_and_update_status(webhook, event_type, meeting, payload, attempt, result) do
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
            http_failure(webhook, status, attempt)

          {:error, reason} ->
            if attempt == 1, do: Webhooks.record_delivery_failure(webhook, to_string(reason))
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to create webhook delivery log", error: inspect(reason))
        {:error, :delivery_log_failed}
    end
  end

  # A non-2xx response is only worth another attempt if a later one could
  # plausibly differ. A 404 or 401 from a subscriber's endpoint is settled: the
  # remaining attempts post the same body to the same URL, fail identically,
  # and then Oban raises `PerformError`, which pages an operator about a
  # subscriber's own misconfiguration. `ErrorAnalysis.classify_error/1` is the
  # existing shared answer to that question (5xx, 408, 425 and 429 transient;
  # 401, 403 and 404 hard), already relied on by the integration health checks,
  # so the retry policy stays in one place instead of drifting per worker.
  defp http_failure(webhook, status, attempt) do
    reason = "HTTP #{status}"

    case ErrorAnalysis.classify_error({:http_error, status, reason}) do
      :transient ->
        # Recorded on the first attempt only, so one failing delivery advances
        # the circuit breaker by one rather than once per retry.
        if attempt == 1, do: Webhooks.record_delivery_failure(webhook, reason)
        {:error, {:http_error, status}}

      :hard ->
        # No retries follow, so this is the only chance to record the failure.
        Webhooks.record_delivery_failure(webhook, reason)
        {:discard, reason}
    end
  end

  # Truncate response to prevent database bloat and ensure UTF-8 compatibility
  @spec truncate_response(String.t() | term() | nil) :: String.t() | nil
  defp truncate_response(nil), do: nil

  defp truncate_response(response) when is_binary(response) do
    safe_response =
      if String.printable?(response) do
        response
      else
        inspect(response, binaries: :as_strings, limit: 5000)
      end

    if String.length(safe_response) > 5000 do
      String.slice(safe_response, 0, 5000) <> "... (truncated)"
    else
      safe_response
    end
  end

  defp truncate_response(response), do: truncate_response(inspect(response))
end
