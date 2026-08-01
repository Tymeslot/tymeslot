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
end
