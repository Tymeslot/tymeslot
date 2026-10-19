defmodule Tymeslot.Workers.EmailWorker do
  @moduledoc """
  Oban worker for executing email sending jobs with intelligent retry and error handling.

  This worker executes email jobs enqueued by `Tymeslot.Emails.EmailScheduler`.
  It handles:
  - Sending confirmation emails after meeting creation
  - Sending reminder emails before meetings
  - Smart retry logic with exponential backoff
  - Error categorisation for appropriate handling
  - Timeouts for external service calls

  To schedule email jobs, use `Tymeslot.Emails.EmailScheduler` — do not call
  `new/2` directly from application code.
  """

  use Oban.Worker,
    queue: :emails,
    # With the backoff below, ten attempts ride out about six minutes of a
    # failing provider. An open mail circuit snoozes instead and spends none.
    max_attempts: 10,
    # Higher priority (0-3, lower number = higher priority)
    priority: 1

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Workers.Bounded
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.TransactionalEmailDelivery
  require Logger

  # Every send is bounded by `Delivery.send_deadline_ms/0`, so the job timeout
  # is a backstop for a wedged job rather than a send timeout, and it must
  # outlast the longest legitimate job: a booking confirmation to the
  # organiser, the attendee and every guest, each allowed the full send
  # deadline, plus one deadline's headroom for building the emails. A fixed
  # 30 seconds let two stalled sends exhaust it, and a timed-out job is
  # discarded, so the recipients after them were never emailed.
  # `:email_timeout_ms` overrides it (e.g. lowered in tests).
  @sends_beyond_guests 2
  @headroom_deadlines 1
  # 1 second base for exponential backoff
  @backoff_cap_ms 120_000
  @ambiguous_retry "ambiguous_timeout"
  @backoff_base_ms 1_000
  # The actions that deliver admin alerts (`AdminAlertScheduler.actions/0`),
  # as a literal for use in guards.
  @admin_alert_actions ["send_admin_alert", "send_admin_alert_digest"]

  @doc """
  Performs the email job based on the action specified in the args.
  Implements exponential backoff for retries.
  """
  @behaviour ExpectedJobOutcome

  # The meeting is gone or cancelled, a handler declares the discard expected,
  # the recipient already raised its own alert, or only the owner can fix the
  # integration the email was about. Timeouts, invalid addresses and missing
  # actions are recorded.
  @meeting_gone "Meeting not found"
  @meeting_cancelled "Meeting cancelled"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@meeting_gone, @meeting_cancelled] or
        EmailHandlers.expected_discard?(reason) or
        TransactionalEmailDelivery.recipient_rejected?(reason) or
        reason == ReauthHandling.discard_reason()

  # Every job is checked against `EmailActions` as it is built, so an unknown
  # action or a missing required arg fails the insert, where the caller can
  # see it, rather than the job.
  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts) do
    args
    |> super(opts)
    |> EmailActions.validate(args)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action} = args, attempt: attempt} = job) do
    # `user_id` in the args is already Logger metadata and error context:
    # `Tymeslot.Infrastructure.ObanLogger` sets it at job start.
    Logger.metadata(job_id: job.id, attempt: attempt)

    execute_email_job_with_timeout(action, args, job)
  end

  def perform(%Oban.Job{args: args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    Logger.error("EmailWorker job missing action parameter",
      arg_keys: Map.keys(args)
    )

    {:discard, "Missing action parameter"}
  end

  # Private functions

  defp handle_result(result, job) do
    case result do
      :ok ->
        :ok

      {:error, error_type} ->
        handle_email_error(error_type, job)

      {:discard, reason} ->
        {:discard, reason}

      _other ->
        handle_unexpected_email_result(result)
    end
  end

  # `:rate_limited`, `:circuit_open`, and `{:recipient_rejected, _}` all mean
  # something other than an ordinary retry, and mean the same thing for every
  # email job — the policy for them lives once in `TransactionalEmailDelivery`
  # and is shared with the Stripe-triggered workers that deliver outside this
  # worker entirely. `failure_message` is unused by those three cases.
  defp handle_email_error(:rate_limited, %Oban.Job{} = job) do
    TransactionalEmailDelivery.handle_failure(:rate_limited, "",
      executions: SnoozePolicy.executions(job)
    )
  end

  defp handle_email_error(:circuit_open, %Oban.Job{} = job) do
    TransactionalEmailDelivery.handle_failure(:circuit_open, "",
      executions: SnoozePolicy.executions(job)
    )
  end

  defp handle_email_error({:recipient_rejected, reason}, %{args: args}) do
    TransactionalEmailDelivery.handle_failure({:recipient_rejected, reason}, "",
      action: args["action"],
      meeting_id: args["meeting_id"]
    )
  end

  defp handle_email_error(:invalid_email, _job) do
    Logger.error("Invalid email address, discarding job")
    {:discard, "Invalid email address"}
  end

  defp handle_email_error(:meeting_not_found, _job) do
    Logger.error("Meeting not found, discarding job")
    {:discard, @meeting_gone}
  end

  defp handle_email_error(:meeting_cancelled, _job) do
    Logger.info("Meeting cancelled, discarding job")
    {:discard, @meeting_cancelled}
  end

  # Some guests were not reached; their sends are claimed per guest, so the
  # retry writes only to them.
  defp handle_email_error({:guest_emails_failed, count}, _job) do
    {:error, "#{count} guest email(s) failed"}
  end

  # Any other reason retries with backoff. It is recorded on the job, so it
  # says what went wrong, but redacted and with addresses masked, as a
  # provider's error body can name the recipient. A message a handler wrote
  # is its own text and kept as it is.
  defp handle_email_error(reason, _job) when is_binary(reason), do: {:error, reason}
  defp handle_email_error(reason, _job), do: {:error, LogFormat.reason(reason)}

  defp handle_unexpected_email_result(result) do
    formatted = LogFormat.reason(result)
    Logger.error("Unexpected result from email job", result: formatted)
    {:error, "Unexpected result: " <> formatted}
  end

  defp execute_email_job_with_timeout(action, args, job) do
    timeout_ms = email_timeout_ms()
    policy = ambiguous_timeout_policy(job)

    case Bounded.run(
           fn ->
             Delivery.with_ambiguous_timeouts(
               policy,
               fn -> EmailHandlers.execute_email_action(action, args, job.id) end,
               on_ambiguous: fn -> record_ambiguous_retry(job, action) end
             )
           end,
           timeout_ms
         ) do
      {:ok, {result, _ambiguous?}} ->
        handle_result(result, job)

      {:exit, reason} ->
        Logger.error("Email job crashed",
          action: action,
          job_id: job.id,
          reason: LogFormat.reason(reason)
        )

        {:error, "Email job crashed: #{LogFormat.reason(reason)}"}

      :timeout ->
        handle_timeout(action, timeout_ms, job)
    end
  end

  # A send that timed out after the message may have been handed over is
  # retried once, never more (decision of 2026-10-07: a rare duplicate over a
  # lost email, at most one extra copy). The first such timeout records it on
  # the job as it happens, from inside the run, so the record stands even if
  # the run then crashes; every later run assumes such a send delivered. The
  # record is per job, not per copy: once one copy has had its retry, an
  # ambiguous timeout on another copy of the same job is assumed delivered. Copies a
  # handler claims (`DeliveryClaims`) are kept once sent or assumed sent, so
  # none of them goes out again whatever happens after.
  defp ambiguous_timeout_policy(%Oban.Job{id: job_id}) do
    if DeliveryClaims.recall(job_id, @ambiguous_retry), do: :assume_delivered, else: :retry_once
  end

  defp record_ambiguous_retry(%Oban.Job{id: job_id}, action) do
    _kept = DeliveryClaims.remember(job_id, @ambiguous_retry, "retried")

    Logger.warning("Email job retrying a send that may have gone out; it will not retry it again",
      action: action,
      job_id: job_id
    )
  end

  # An admin alert, or the daily digest of them, is the one email where a
  # duplicate costs nothing and a loss costs the operator the incident. An
  # SMTP outage often shows as a hang rather than a refusal, so a discard here
  # would defeat the long retry schedule `AdminAlertScheduler` gives the
  # alert: retry instead.
  defp handle_timeout(action, timeout_ms, job)
       when action in @admin_alert_actions do
    Logger.warning("Admin alert email timed out; retrying",
      action: action,
      timeout_ms: timeout_ms,
      job_id: job.id,
      attempt: job.attempt
    )

    {:error, "Email sending timed out"}
  end

  # A hard timeout is ambiguous: the message may already be on the wire.
  # Discard rather than letting Oban retry, which would re-send a possibly
  # delivered email. A genuinely lost mail can be re-requested by the user.
  defp handle_timeout(action, timeout_ms, job) do
    Logger.warning("Email job timed out; discarding to avoid duplicate sends",
      action: action,
      timeout_ms: timeout_ms,
      job_id: job.id,
      attempt: job.attempt
    )

    {:discard, "Email sending timed out"}
  end

  defp email_timeout_ms do
    Application.get_env(:tymeslot, :email_timeout_ms) ||
      (Guests.max_guests() + @sends_beyond_guests + @headroom_deadlines) *
        Delivery.send_deadline_ms()
  end

  # 1 s, 2 s, 4 s ... capped at 2 minutes: about six minutes over the ten
  # attempts. A job's legs share those attempts, each retry sending only the
  # copies not yet sent, so a short outage costs a delay rather than a copy.
  defp calculate_backoff(attempt) do
    round(min(@backoff_base_ms * :math.pow(2, attempt - 1), @backoff_cap_ms))
  end

  # Admin alerts and their daily digest retry on their own, much longer
  # schedule; see `AdminAlertScheduler` for why.
  @impl Oban.Worker
  def backoff(%Oban.Job{args: %{"action" => action}} = job)
      when action in @admin_alert_actions,
      do: AdminAlertScheduler.backoff(job)

  def backoff(%Oban.Job{attempt: attempt}) do
    # convert ms to seconds for Oban backoff
    div(calculate_backoff(attempt), 1_000)
  end
end
