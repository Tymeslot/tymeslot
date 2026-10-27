defmodule Tymeslot.Notifications.Email.DeliveryOutcome do
  @moduledoc """
  Translates a `Tymeslot.Emails.Delivery` failure reason into the job outcome
  `Tymeslot.Workers.EmailWorker` acts on.

  Handlers replace a delivery failure with a message describing which email
  failed, which is what an operator wants to read. That flattening also erased
  two reasons the worker must treat differently from an ordinary retry:

    * `:circuit_open` — the provider's breaker is open, so every attempt made
      inside the recovery window fails instantly. The worker snoozes past the
      window rather than spending attempts on a provider it knows is unavailable.
    * `{:recipient_rejected, _}` — the address is permanently undeliverable, so
      no number of retries can succeed. The worker discards.

  Any other reason keeps the caller's message and retries exactly as before.

  This module only preserves the reason; deciding what to do with it stays in
  `Tymeslot.Workers.EmailWorker`, so handlers that already return their raw
  delivery reason get the same treatment without passing through here.

  `from_results/3` and `combine/3` apply the same rule to a job that sends to
  several recipients, each claimed or stamped as it goes out.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat

  @spec from_error(term(), String.t()) :: {:error, term()}
  def from_error(:circuit_open, _message), do: {:error, :circuit_open}

  def from_error({:recipient_rejected, _reason} = rejection, _message),
    do: {:error, rejection}

  def from_error(_reason, message), do: {:error, message}

  @doc """
  The job outcome for a send to several recipients whose deliveries are each
  recorded as they succeed (a sent stamp or a `DeliveryClaims` claim), so a
  retry repeats only what has not gone out.

  `:ok` once every result is a success (`{:ok, _}`, or the bare `:ok` a claim
  already taken by an earlier run returns). Otherwise the job retries:
  `{:error, _}` with the actionable reason `first_actionable/1` finds (an open
  circuit snoozes; a permanent rejection with nothing else outstanding
  discards), or a message naming the email.
  """
  @spec from_results(String.t(), keyword(), [term()]) :: :ok | {:error, term()}
  def from_results(label, metadata, results) do
    case Enum.reject(results, &succeeded?/1) do
      [] ->
        :ok

      failures ->
        Logger.warning(
          "Some emails failed and will be retried",
          metadata ++ [label: label, failures: Enum.map(failures, &LogFormat.reason/1)]
        )

        {:error, first_actionable(failures) || "Failed to send #{label} emails"}
    end
  end

  @doc """
  One outcome for a job's several legs (the participants' copies, the
  guests', a request's two emails), each already a job outcome in its own
  right, so it runs every leg before deciding.

  `:ok` when every leg succeeded; a single failing leg's outcome as it is;
  several through `from_results/3`, where a failure a retry can fix
  outweighs a rejected address, so one suppressed recipient never stops
  another's retry.
  """
  @spec combine(String.t(), keyword(), [term()]) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def combine(label, metadata, legs) do
    case Enum.reject(legs, &succeeded?/1) do
      [] -> :ok
      [failure] -> failure
      _failures -> from_results(label, metadata, legs)
    end
  end

  defp succeeded?(:ok), do: true
  defp succeeded?({:ok, _result}), do: true
  defp succeeded?(_result), do: false

  @doc """
  The list form of the same contract, for a handler that sends to more than
  one recipient per job and must combine their results into one outcome.

  Returns the bare reason (not wrapped in `{:error, _}`, matching
  `from_error/2`'s per-result inputs) so callers compose it the way they
  already do for their other branches, or `nil` when nothing here overrides
  an ordinary retry.

  `:circuit_open` always wins: the provider is down for every recipient, so
  the worker snoozes past the outage regardless of what else is in the list.
  A permanent rejection is only returned when *every* result that isn't a
  success is a rejection — i.e. no recipient in the list still needs a
  retryable attempt. A rejection mixed with a genuinely retryable failure
  must not surface here, or the caller's retry-worthy recipient gets
  discarded along with the dead one.
  """
  @spec first_actionable([term()]) :: term() | nil
  def first_actionable(results) do
    if Enum.any?(results, &match?({:error, :circuit_open}, &1)) do
      :circuit_open
    else
      terminal_rejection(results)
    end
  end

  defp terminal_rejection(results) do
    failures = Enum.reject(results, &match?({:ok, _result}, &1))

    if failures != [] and Enum.all?(failures, &match?({:error, {:recipient_rejected, _}}, &1)) do
      Enum.find_value(failures, fn {:error, rejection} -> rejection end)
    end
  end
end
