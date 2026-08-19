defmodule Tymeslot.Workers.VideoRoom.ErrorPolicy do
  @moduledoc """
  Classifying video room creation failures and deciding what Oban should do
  with them.

  Two questions, deliberately kept apart from the worker that asks them:

  `categorize/1` normalises whatever the video provider or the meetings context
  handed back into a small, closed set of reasons. Provider errors arrive in
  several shapes (bare atoms, tagged tuples, HTTP statuses), and every caller
  reading those shapes for itself is how a new provider quietly stops being
  retried.

  `to_result/2` turns a reason into an Oban verdict. The distinction that
  matters is *whose* problem it is: a rate limit or an outage will pass on its
  own and is worth snoozing, whereas bad credentials or a missing meeting will
  fail identically on every attempt and should be discarded rather than
  consuming the queue for ten tries.
  """

  require Logger

  alias Tymeslot.Infrastructure.VideoCircuitBreaker

  @typedoc "A normalised failure reason."
  @type reason :: atom() | String.t() | term()

  @typedoc "An Oban `perform/1` return value."
  @type result :: :ok | {:error, term()} | {:snooze, pos_integer()} | {:discard, String.t()}

  # Rate-limit snoozes grow with the attempt but never exceed five minutes;
  # beyond that the recovery policy is the better instrument.
  @max_rate_limit_snooze_seconds 300
  @rate_limit_snooze_step_seconds 60

  # A provider outage is worth waiting out at a fixed, unhurried interval.
  @service_unavailable_snooze_seconds 120

  # Extra seconds added on top of the breaker's recovery window when
  # snoozing, picked at random per job — same jitter `EmailWorker` and
  # `TransactionalEmailDelivery` add to their own `:circuit_open` snooze, so a
  # queue full of jobs snoozed during the same outage doesn't all wake in the
  # same second and stampede the breaker's half-open probe slots.
  @circuit_open_jitter_seconds 30

  # Failures that will repeat identically on every attempt, and the reason
  # recorded against the discarded job.
  @terminal %{
    unauthorized: "Authentication failed",
    meeting_not_found: "Meeting not found",
    invalid_configuration: "Invalid configuration",
    video_integration_missing: "Video integration missing",
    video_integration_inactive: "Video integration inactive"
  }

  @doc """
  Normalises a raw failure into `{:error, reason}` with a known reason where one
  is recognised, passing anything else through untouched for a plain retry.
  """
  @spec categorize(term()) :: {:error, reason()}
  def categorize({:unauthorized, _details}), do: {:error, :unauthorized}
  def categorize(:unauthorized), do: {:error, :unauthorized}

  def categorize({:configuration_error, _details}), do: {:error, :invalid_configuration}
  def categorize(:configuration_error), do: {:error, :invalid_configuration}

  def categorize({:http_error, status}) when is_integer(status) and status in 500..599,
    do: {:error, :service_unavailable}

  def categorize(:rate_limited), do: {:error, :rate_limited}
  def categorize(:not_found), do: {:error, :meeting_not_found}
  def categorize(:video_integration_missing), do: {:error, :video_integration_missing}
  def categorize(:video_integration_inactive), do: {:error, :video_integration_inactive}
  def categorize(other), do: {:error, other}

  @doc """
  Whether this reason is one no number of retries will fix.

  Callers check this before spending the job's remaining attempts, and use
  `discard_reason/1` for the message recorded against the discarded job.
  """
  @spec terminal?(reason()) :: boolean()
  def terminal?(reason) when is_atom(reason), do: Map.has_key?(@terminal, reason)
  def terminal?(_other), do: false

  @doc """
  The reason recorded against a job discarded for a terminal failure.
  """
  @spec discard_reason(reason()) :: String.t()
  def discard_reason(reason), do: Map.fetch!(@terminal, reason)

  @doc """
  Turns a categorised failure into the value Oban should receive.
  """
  @spec to_result(reason(), pos_integer()) :: result()
  def to_result(:rate_limited, attempt) do
    seconds =
      min(@max_rate_limit_snooze_seconds, @rate_limit_snooze_step_seconds * attempt)

    Logger.warning("Video API rate limited, snoozing", snooze_seconds: seconds)
    {:snooze, seconds}
  end

  def to_result(:service_unavailable, _attempt),
    do: {:snooze, @service_unavailable_snooze_seconds}

  # The provider's circuit breaker is open, so every attempt made before it
  # recovers fails instantly. Snoozing past the recovery window costs no
  # attempt and waits the breaker out, rather than burning the job's limited
  # retries on a call known to be refused.
  def to_result(:circuit_open, _attempt) do
    snooze_seconds =
      VideoCircuitBreaker.max_recovery_seconds() + :rand.uniform(@circuit_open_jitter_seconds)

    Logger.warning("Video circuit breaker open, snoozing past the recovery window",
      snooze_seconds: snooze_seconds
    )

    {:snooze, snooze_seconds}
  end

  def to_result(reason, _attempt) when is_atom(reason) do
    if terminal?(reason) do
      Logger.error("Discarding video room job", reason: reason)
      {:discard, discard_reason(reason)}
    else
      {:error, reason}
    end
  end

  # Anything unrecognised retries on the job's normal schedule.
  def to_result(reason, _attempt), do: {:error, reason}
end
