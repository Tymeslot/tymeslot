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

  alias Tymeslot.Infrastructure.Logging.LogFormat

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
          organizer_result: LogFormat.reason(organizer_result),
          attendee_result: LogFormat.reason(attendee_result)
        ]
    )

    if delivered?(organizer_result) or delivered?(attendee_result) do
      {:discard, "Partial #{label} failure: retry would duplicate"}
    else
      from_error(
        first_actionable([organizer_result, attendee_result]),
        "Failed to send #{label} emails"
      )
    end
  end

  # `{:ok, :skipped}` means a recipient was deliberately not sent to (e.g. a
  # last-leaver seat cancellation with no organiser notification), not that
  # something already went out. Counting it as delivered here would make a
  # genuine single-recipient failure look like a partial success, discarding
  # a job a retry could still fix instead of retrying it.
  defp delivered?(result), do: match?({:ok, outcome} when outcome != :skipped, result)

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
