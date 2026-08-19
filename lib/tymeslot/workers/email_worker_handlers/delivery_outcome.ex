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

  `from_dual_send/4` applies the same rule to the organiser/attendee pair the
  meeting handlers send, which additionally has a partial-success outcome the
  single-recipient case cannot produce.
  """

  require Logger

  @spec from_error(term(), String.t()) :: {:error, term()}
  def from_error(:circuit_open, _message), do: {:error, :circuit_open}

  def from_error({:recipient_rejected, _reason} = rejection, _message),
    do: {:error, rejection}

  def from_error(_reason, message), do: {:error, message}

  @doc """
  The job outcome for a paired organiser/attendee send.

  `:ok` once both succeeded, `{:discard, _}` on a partial send so a retry
  cannot duplicate the email that already went out, and `{:error, _}` when
  neither did — preserving an actionable reason where one is present, exactly
  as `from_error/2` does for a single recipient. `label` names the email in
  the log line and the outcome message (e.g. "seat confirmation"); `metadata`
  is the keyword list of identifiers to log alongside it.
  """
  @spec from_dual_send(String.t(), keyword(), term(), term()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def from_dual_send(label, metadata, organizer_result, attendee_result)

  def from_dual_send(_label, _metadata, {:ok, _organizer}, {:ok, _attendee}), do: :ok

  def from_dual_send(label, metadata, organizer_result, attendee_result) do
    Logger.warning(
      "Some emails may have failed",
      metadata ++
        [
          label: label,
          organizer_result: inspect(organizer_result),
          attendee_result: inspect(attendee_result)
        ]
    )

    if match?({:ok, _}, organizer_result) or match?({:ok, _}, attendee_result) do
      {:discard, "Partial #{label} failure: retry would duplicate"}
    else
      from_error(
        actionable_reason([organizer_result, attendee_result]),
        "Failed to send #{label} emails"
      )
    end
  end

  @doc """
  The first reason in `results` the worker must act on differently from an
  ordinary retry, or `nil` when none of them is one.
  """
  @spec actionable_reason([term()]) :: term() | nil
  def actionable_reason(results) do
    Enum.find_value(results, fn
      {:error, :circuit_open} -> :circuit_open
      {:error, {:recipient_rejected, _reason} = rejection} -> rejection
      _other -> nil
    end)
  end
end
