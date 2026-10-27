defmodule Tymeslot.Workers.WebhookWorker do
  @moduledoc """
  Oban worker for delivering webhook notifications.

  Handles:
  - HTTP POST delivery with timeout protection
  - Signed requests: an `X-Tymeslot-Signature` HMAC-SHA256 over the
    timestamp and the exact body posted (`Tymeslot.Webhooks.sign/3`),
    alongside the plain `X-Tymeslot-Token`
  - Retries spread over hours (`backoff/1`), so a receiver that is down for
    a deploy still gets the event
  - Circuit breaker (auto-disable after consecutive failures)
  - Delivery logging and metrics
  - At-most-once posting per job, and a stable delivery id on the wire

  ## Duplicate deliveries

  The post is claimed through `Tymeslot.Workers.DeliveryClaims` before it is
  sent, so a job the Oban lifeline rescues after the post went out does not
  post it again. A post that failed is still retried as before, and a retry
  after a timeout can reach a receiver that did get the first request.

  Only the post itself is claimed. The delivery log and the webhook's status
  are written after the claim settles, so a log write that fails after a
  successful post cannot release the claim and post the event again.

  Every request therefore carries an `X-Tymeslot-Delivery-Id` header: the
  Oban job id, identical on every attempt of the same delivery and different
  for every other one. A receiver that records it can discard a second copy.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 8,
    priority: 2

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.MeetingNotificationJob

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
    approval_declined_at
  )a

  @delivery_id_header "X-Tymeslot-Delivery-Id"

  @datetime_snapshot_fields ~w(
    cancelled_at approval_requested_at approval_deadline_at approval_resolved_at
    approval_declined_at
  )a

  @doc """
  Captures the event-defining fields of a meeting for `schedule_delivery/4`.

  Called by the trigger site at the moment the event fires, so a retried
  delivery can replay what that event asserted rather than whatever the
  meeting looks like by the time the retry runs.

  A group meeting's seat (`Tymeslot.Meetings.SeatView`) also pins the seats
  taken on the slot when the event fired, under `"seats_taken"`, and the
  seat a move replaced, under `"previous_seat"`.
  """
  @spec snapshot(MeetingSchema.t()) :: map()
  def snapshot(%MeetingSchema{} = meeting) do
    meeting
    |> Map.take(@snapshot_fields)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), encode_snapshot_field(value)} end)
    |> maybe_put_seats_taken(SeatView.seats_taken(meeting))
    |> maybe_put_previous_seat(SeatView.previous_seat(meeting))
  end

  defp maybe_put_seats_taken(snapshot, nil), do: snapshot
  defp maybe_put_seats_taken(snapshot, seats), do: Map.put(snapshot, "seats_taken", seats)

  defp maybe_put_previous_seat(snapshot, nil), do: snapshot

  defp maybe_put_previous_seat(snapshot, previous) do
    Map.put(snapshot, "previous_seat", %{
      "seat_id" => previous.seat_id,
      "meeting_id" => previous.meeting_id,
      "start_time" => DateTime.to_iso8601(previous.start_time)
    })
  end

  defp encode_snapshot_field(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_snapshot_field(value), do: value

  @behaviour ExpectedJobOutcome

  # The work no longer applies, or the user's own endpoint refuses it: a
  # blocked or broken redirect, or a 4xx it answers for good. Missing
  # parameters and a 5xx are recorded.
  @blocked_by_ssrf :blocked_by_ssrf
  @blocked_redirect :blocked_redirect
  @too_many_redirects :too_many_redirects
  @redirect_missing_location :redirect_missing_location
  @refused_destinations [
    @blocked_by_ssrf,
    @blocked_redirect,
    @too_many_redirects,
    @redirect_missing_location
  ]
  @http_status_prefix "HTTP "
  @gone "Webhook or meeting not found"
  @disabled "Webhook is disabled"
  @insufficient_plan "Insufficient plan"
  @feature_disabled "Automations are switched off"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason) when is_binary(reason) do
    reason in [@gone, @disabled, @insufficient_plan, @feature_disabled] or
      String.starts_with?(reason, @http_status_prefix <> "4")
  end

  def expected_outcome?(reason), do: reason in @refused_destinations

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

    with {:ok, webhook} <- WebhookQueries.get_webhook(webhook_id),
         :ok = ErrorTracking.put_context(user_id: webhook.user_id),
         :ok <- feature_gate(webhook.user_id, webhook_id, event_type),
         {:ok, meeting} <- fetch_meeting(meeting_id, args["participant_id"], args["snapshot"]),
         :ok <- deliver_once(webhook, event_type, meeting, job) do
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
    Logger.warning(@gone,
      webhook_id: webhook_id,
      meeting_id: meeting_id
    )

    {:discard, @gone}
  end

  defp handle_delivery_error({:error, :disabled}, webhook_id, _meeting_id, _event_type) do
    Logger.info("Webhook is disabled, discarding job", webhook_id: webhook_id)
    {:discard, @disabled}
  end

  defp handle_delivery_error({:error, :insufficient_plan}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery blocked - insufficient plan",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, @insufficient_plan}
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

    {:discard, @blocked_by_ssrf}
  end

  defp handle_delivery_error({:error, :blocked_redirect}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery discarded - redirect blocked",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, @blocked_redirect}
  end

  defp handle_delivery_error({:error, :too_many_redirects}, webhook_id, _meeting_id, event_type) do
    Logger.info("Webhook delivery discarded - too many redirects",
      webhook_id: webhook_id,
      event_type: event_type
    )

    {:discard, @too_many_redirects}
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

    {:discard, @redirect_missing_location}
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

  `participant_id` names the seat of a group meeting the event is about (see
  `Tymeslot.Meetings.SeatView`); the delivery then describes that seat's
  booking. Each seat is its own delivery, so it is part of the uniqueness
  key; a solo meeting passes `nil`, which is stored and keyed as well, so a
  seat's delivery and the meeting's own are never taken for duplicates (see
  `Tymeslot.Workers.MeetingNotificationJob.schedule/5`).
  """
  @spec schedule_delivery(integer(), String.t(), binary(), map() | nil, binary() | nil) ::
          :ok | {:error, term()}
  def schedule_delivery(
        webhook_id,
        event_type,
        meeting_id,
        snapshot \\ nil,
        participant_id \\ nil
      ) do
    args =
      maybe_put_snapshot(
        %{
          "webhook_id" => webhook_id,
          "event_type" => event_type,
          "meeting_id" => meeting_id
        },
        snapshot
      )

    # The snapshot is part of the key: it is what the delivery replays, so a
    # waiting job only absorbs a duplicate that would post the same payload.
    MeetingNotificationJob.schedule(
      __MODULE__,
      args,
      participant_id,
      [:webhook_id, :event_type, :meeting_id, :snapshot],
      queue: :webhooks
    )
  end

  # Seconds to wait after each failed attempt: 30s, 2m, 10m, 30m, 1h, 3h,
  # then 6h. With `max_attempts: 8` the last retry lands about eleven hours
  # after the first, so a receiver down for a deploy or a short outage still
  # receives the event, while any 4xx but a 408, 425 or 429 is discarded at
  # once.
  @backoff_seconds {30, 120, 600, 1_800, 3_600, 10_800, 21_600}

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    elem(@backoff_seconds, min(attempt, tuple_size(@backoff_seconds)) - 1)
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
  #
  # A seat's delivery (`participant_id` set) describes that seat's booking:
  # the participant as the attendee, their guests only, and the seat count
  # the event fired with. The snapshot is replayed over the seat view, so a
  # seat given up reads as cancelled with the time it was given up.
  defp fetch_meeting(meeting_id, participant_id, snapshot) do
    with {:ok, meeting} <- MeetingQueries.get_meeting_with_guests(meeting_id),
         {:ok, meeting} <- maybe_seat_view(meeting, participant_id, snapshot) do
      {:ok, apply_snapshot(meeting, snapshot)}
    end
  end

  defp maybe_seat_view(meeting, nil, _snapshot), do: {:ok, meeting}

  defp maybe_seat_view(meeting, participant_id, snapshot) do
    SeatView.load(
      meeting,
      participant_id,
      snapshot_seats_taken(snapshot),
      snapshot_previous_seat(snapshot)
    )
  end

  defp snapshot_seats_taken(%{"seats_taken" => seats}) when is_integer(seats), do: seats
  defp snapshot_seats_taken(_snapshot), do: nil

  defp snapshot_previous_seat(%{
         "previous_seat" => %{
           "seat_id" => seat_id,
           "meeting_id" => meeting_id,
           "start_time" => start_time
         }
       }) do
    case DateTime.from_iso8601(start_time) do
      {:ok, start_time, _offset} ->
        %{seat_id: seat_id, meeting_id: meeting_id, start_time: start_time}

      {:error, _reason} ->
        nil
    end
  end

  defp snapshot_previous_seat(_snapshot), do: nil

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

  # The claim covers the post alone. Recording the outcome happens once the
  # claim has settled: a delivered post keeps its claim whatever the log write
  # then does, so a rescued or retried run never posts it a second time. A
  # bare `:ok` is an earlier run's claim, whose outcome that run recorded.
  defp deliver_once(webhook, event_type, meeting, job) do
    case DeliveryClaims.once(job, "webhook", fn ->
           deliver_webhook(webhook, event_type, meeting, job)
         end) do
      :ok ->
        :ok

      {:ok, {:posted, payload, result}} ->
        log_and_update_status(webhook, event_type, meeting, payload, job.attempt, result)

      {:not_delivered, payload, result} ->
        log_and_update_status(webhook, event_type, meeting, payload, job.attempt, result)

      {:error, _reason} = error ->
        error
    end
  end

  defp deliver_webhook(%WebhookSchema{} = webhook, event_type, meeting, job) do
    if WebhookSchema.should_be_active?(webhook) do
      do_deliver_webhook(webhook, event_type, meeting, job)
    else
      {:error, :disabled}
    end
  end

  # A plan that no longer covers automations discards the job and leaves the
  # webhook as it is, so it resumes by itself once the plan does again.
  defp feature_gate(user_id, webhook_id, event_type) do
    case MeetingNotificationJob.feature_gate(user_id) do
      :ok ->
        :ok

      {:revoked, _reason} ->
        Logger.info("Feature access denied for webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type
        )

        {:error, :insufficient_plan}

      {:discard, :feature_disabled} ->
        Logger.info("Automations are switched off, discarding webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type
        )

        {:discard, @feature_disabled}

      {:error, :feature_access_checker_failed} = error ->
        Logger.warning("Feature access check failed for webhook delivery",
          webhook_id: webhook_id,
          event_type: event_type
        )

        error
    end
  end

  defp do_deliver_webhook(webhook, event_type, meeting, %Oban.Job{} = job) do
    webhook = WebhookSchema.decrypt_token(webhook)
    payload = PayloadBuilder.build_payload(event_type, meeting, to_string(webhook.id))
    body = Jason.encode!(payload)

    # Signed over `body` itself, the bytes posted, so the receiver can verify
    # the signature against the raw request body it reads.
    headers =
      body
      |> Webhooks.build_headers(webhook.webhook_token)
      |> put_delivery_id(job)

    case HttpDelivery.post(webhook.url, body, headers) do
      {:ok, status, _body} = result when status in 200..299 -> {:ok, {:posted, payload, result}}
      result -> {:not_delivered, payload, result}
    end
  end

  # The job id is the delivery id because it is the one identifier that stays
  # the same across every attempt of a delivery, a lifeline rescue included,
  # and differs between deliveries. A job that was never persisted has none.
  defp put_delivery_id(headers, %Oban.Job{id: nil}), do: headers

  defp put_delivery_id(headers, %Oban.Job{id: job_id}),
    do: [{@delivery_id_header, Integer.to_string(job_id)} | headers]

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

    case {WebhookQueries.create_delivery(delivery_attrs), result} do
      # The receiver has the event, so the job is done even if the log row
      # could not be written; retrying would only post it again.
      {{:error, reason}, {:ok, status, _body}} when status in 200..299 ->
        Logger.warning("Failed to create webhook delivery log after a successful delivery",
          error: LogFormat.reason(reason)
        )

        WebhookQueries.record_success(webhook)
        :ok

      {{:error, reason}, _result} ->
        Logger.warning("Failed to create webhook delivery log", error: LogFormat.reason(reason))
        {:error, :delivery_log_failed}

      {{:ok, _delivery}, {:ok, status, _body}} when status in 200..299 ->
        WebhookQueries.record_success(webhook)
        :ok

      # Both failure clauses record the failure on the first attempt only,
      # however the delivery then ends (retried, discarded at once, or
      # discarded on a later attempt), so Oban's retries never count one
      # delivery several times.
      {{:ok, _delivery}, {:ok, status, _body}} ->
        http_failure(webhook, status, attempt)

      {{:ok, _delivery}, {:error, reason}} ->
        if attempt == 1, do: Webhooks.record_delivery_failure(webhook, to_string(reason))
        {:error, reason}
    end
  end

  # A non-2xx response is only worth another attempt if a later one could
  # plausibly differ: a 5xx, a 408 (the receiver timed out), a 425 (it will
  # not process a request that might be replayed yet) or a 429 (it is rate
  # limiting us). Every other status is the subscriber's endpoint
  # answering for good. A 400, 404 or 422 comes back identically on every
  # remaining attempt, eleven hours of them, and then Oban raises
  # `PerformError`, which pages an operator about a subscriber's own
  # misconfiguration. Redirects never reach here: `HttpDelivery` follows them
  # or fails the delivery itself. Network and transport errors take the
  # `{:error, reason}` path in `log_and_update_status/6` and are retried.
  #
  # Both paths record one failure per delivery, so a permanent 400 advances
  # the circuit breaker exactly as far as a 503 does.
  @retryable_statuses [408, 425, 429]

  defp http_failure(webhook, status, attempt) do
    reason = "#{@http_status_prefix}#{status}"

    # Recorded on the first attempt only, so one failing delivery advances the
    # circuit breaker by one, whether it is retried, discarded at once, or
    # discarded on a later attempt after a retryable first failure.
    if attempt == 1, do: Webhooks.record_delivery_failure(webhook, reason)

    if retryable_status?(status),
      do: {:error, {:http_error, status}},
      else: {:discard, reason}
  end

  defp retryable_status?(status), do: status >= 500 or status in @retryable_statuses

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
