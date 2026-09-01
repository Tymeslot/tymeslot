defmodule Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome do
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
  """

  @spec from_error(term(), String.t()) :: {:error, term()}
  def from_error(:circuit_open, _message), do: {:error, :circuit_open}

  def from_error({:recipient_rejected, _reason} = rejection, _message),
    do: {:error, rejection}

  def from_error(_reason, message), do: {:error, message}

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
