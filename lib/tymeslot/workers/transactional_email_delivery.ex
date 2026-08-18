defmodule Tymeslot.Workers.TransactionalEmailDelivery do
  @moduledoc """
  Delivers one email from an Oban worker that calls `Tymeslot.Emails.Delivery`
  directly, and turns the delivery result into that job's outcome.

  These workers sit outside `Tymeslot.Workers.EmailWorker`, so they inherit
  Oban's default backoff, which exhausts five attempts in roughly ninety
  seconds. The mail circuit breaker stays open for five minutes, so without
  this every attempt would be spent while the provider was known-unavailable
  and the email then discarded for good. Snoozing past the recovery window
  costs no attempt — Oban's snooze raises `max_attempts` in step — and is what
  `EmailWorker` already does with the same failure.

  A permanently rejected recipient is discarded for the matching reason: no
  number of retries can reach a dead address, and exhausting the attempts
  raises a permanent-failure alert for what is a recipient problem.
  """

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor

  @circuit_open_jitter_seconds 30

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

  defp handle_failure(:circuit_open, _failure_message, metadata) do
    snooze_seconds =
      CircuitBreakerSupervisor.email_breaker_recovery_seconds() +
        :rand.uniform(@circuit_open_jitter_seconds)

    Logger.warning(
      "Email circuit breaker open, snoozing past the recovery window",
      Keyword.put(metadata, :snooze_seconds, snooze_seconds)
    )

    {:snooze, snooze_seconds}
  end

  defp handle_failure({:recipient_rejected, reason}, _failure_message, metadata) do
    Logger.warning(
      "Recipient permanently undeliverable, discarding job",
      Keyword.put(metadata, :reason, inspect(reason))
    )

    {:discard, "Recipient permanently undeliverable"}
  end

  defp handle_failure(reason, failure_message, metadata) do
    Logger.error(failure_message, Keyword.put(metadata, :reason, inspect(reason)))
    {:error, reason}
  end
end
