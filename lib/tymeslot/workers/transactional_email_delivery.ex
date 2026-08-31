defmodule Tymeslot.Workers.TransactionalEmailDelivery do
  @moduledoc """
  Delivers one email from an Oban worker that calls `Tymeslot.Emails.Delivery`
  directly, and turns the delivery result into that job's outcome.

  `handle_failure/3` is also the policy `Tymeslot.Workers.EmailWorker` calls
  for the same three delivery reasons, so a circuit-open provider, a rate
  limit, and a rejected recipient mean the same thing everywhere in the email
  pipeline rather than being decided twice.

  These workers sit outside `Tymeslot.Workers.EmailWorker`, so they inherit
  Oban's default backoff, which exhausts five attempts in roughly ninety
  seconds. The mail circuit breaker stays open for five minutes, so without
  this every attempt would be spent while the provider was known-unavailable
  and the email then discarded for good. Snoozing past the recovery window
  costs no attempt — Oban's snooze raises `max_attempts` in step.

  A permanently rejected recipient is discarded for the matching reason: no
  number of retries can reach a dead address, and exhausting the attempts
  would raise a permanent-failure alert for what is a recipient problem, not
  an outage. The discard is reported to `AdminAlerts` directly instead, since
  a discard never reaches `ObanFailureAlerter` (it emits `job:stop`, not
  `job:exception`) and a dead recipient — a host's payouts restricted, a
  dispute opened — is exactly the kind of silence an operator needs to know
  about.
  """

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Workers.SnoozePolicy

  @circuit_open_jitter_seconds 30
  # Matches `EmailWorker`'s cap for the same reason; callers here don't
  # necessarily have an attempt number to hand, so this is the ceiling that
  # formula converges on.
  @rate_limited_snooze_seconds 300

  # Bounds how many times a job may snooze past an open breaker or a rate
  # limit before it is let fail normally. 12 snoozes at the ~5 minute mail
  # breaker recovery window is roughly an hour — long enough to ride out a
  # transient provider blip without letting a permanently broken mailer
  # (bad credentials, a revoked API key) snooze silently forever.
  @circuit_open_max_snoozes 12
  @rate_limited_max_snoozes 10

  @typedoc "An Oban `perform/1` return value."
  @type outcome :: :ok | {:error, term()} | {:snooze, pos_integer()} | {:discard, String.t()}

  @doc """
  Delivers `email`, logging `failure_message` with `metadata` when the failure
  is one an ordinary retry can still fix.
  """
  @spec deliver(Swoosh.Email.t(), String.t(), keyword()) :: outcome()
  def deliver(email, failure_message, metadata \\ []) do
    case Delivery.deliver(email) do
      {:ok, _result} -> :ok
      {:error, reason} -> handle_failure(reason, failure_message, metadata)
    end
  end

  @doc """
  Translates a `Tymeslot.Emails.Delivery` failure `reason` into the Oban
  outcome for it: snooze past a provider-side "come back later" signal,
  discard a permanently rejected recipient, or fall back to an ordinary
  retry. `failure_message` is only used for that last, generic case.

  `metadata` may include `:attempt` (the job's current attempt number) to
  scale the `:rate_limited` snooze the same way `EmailWorker` does; callers
  that omit it get the formula's attempt-1 value.
  """
  @spec handle_failure(term(), String.t(), keyword()) :: outcome()
  def handle_failure(:circuit_open, _failure_message, metadata) do
    attempt = Keyword.get(metadata, :attempt, 1)
    base_seconds = CircuitBreakerSupervisor.email_breaker_recovery_seconds()

    case SnoozePolicy.snooze_or_exhaust(attempt,
           max_snoozes: @circuit_open_max_snoozes,
           base_seconds: base_seconds,
           jitter_seconds: @circuit_open_jitter_seconds
         ) do
      {:snooze, snooze_seconds} ->
        Logger.warning(
          "Email circuit breaker open, snoozing past the recovery window",
          Keyword.put(metadata, :snooze_seconds, snooze_seconds)
        )

        {:snooze, snooze_seconds}

      :exhausted ->
        Logger.error(
          "Email circuit breaker still open after the maximum number of snoozes, failing the job",
          Keyword.put(metadata, :max_snoozes, @circuit_open_max_snoozes)
        )

        {:error, "Email circuit breaker did not recover after the maximum wait"}
    end
  end

  def handle_failure(:rate_limited, _failure_message, metadata) do
    attempt = Keyword.get(metadata, :attempt, 1)
    base_seconds = min(@rate_limited_snooze_seconds, 60 * attempt)

    case SnoozePolicy.snooze_or_exhaust(attempt,
           max_snoozes: @rate_limited_max_snoozes,
           base_seconds: base_seconds
         ) do
      {:snooze, snooze_seconds} ->
        Logger.warning(
          "Email service rate limited, snoozing",
          Keyword.put(metadata, :snooze_seconds, snooze_seconds)
        )

        {:snooze, snooze_seconds}

      :exhausted ->
        Logger.error(
          "Email service still rate limited after the maximum number of snoozes, failing the job",
          Keyword.put(metadata, :max_snoozes, @rate_limited_max_snoozes)
        )

        {:error, "Email service still rate limited after the maximum wait"}
    end
  end

  def handle_failure({:recipient_rejected, reason}, _failure_message, metadata) do
    Logger.warning(
      "Recipient permanently undeliverable, discarding job",
      Keyword.put(metadata, :reason, inspect(reason))
    )

    AdminAlerts.report(:recipient_email_rejected,
      summary: "Recipient permanently undeliverable, email discarded",
      reason: reason,
      context: Map.new(metadata)
    )

    {:discard, "Recipient permanently undeliverable"}
  end

  def handle_failure(reason, failure_message, metadata) do
    Logger.error(failure_message, Keyword.put(metadata, :reason, inspect(reason)))
    {:error, reason}
  end
end
