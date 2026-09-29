defmodule Tymeslot.Infrastructure.ErrorTracking.JobDiscardedError do
  @moduledoc """
  Carries an Oban job that was given up on into ErrorTracker: its worker
  returned `{:discard, reason}` or `{:cancel, reason}`, or the job failed on
  its last attempt and Oban discarded it (`:exhausted`).

  Built by `Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes`. The message
  names the worker, the outcome and the reason; `reason` keeps the reason,
  bounded, for the occurrence's context.
  """

  alias Tymeslot.Infrastructure.ErrorTracking.HandledError

  defexception [:worker, :outcome, :reason, :message]

  @type outcome :: :discard | :cancel | :exhausted

  @type t :: %__MODULE__{
          worker: String.t(),
          outcome: outcome(),
          reason: String.t(),
          message: String.t()
        }

  @max_reason_length 300

  @impl Exception
  def exception({worker, outcome, reason}) when outcome in [:discard, :cancel, :exhausted] do
    text = reason_text(reason)

    %__MODULE__{
      worker: worker,
      outcome: outcome,
      reason: text,
      message: "#{worker} #{verb(outcome)}: #{text}"
    }
  end

  @doc """
  Renders a reason as text: a string as it is, an exception as its module and
  message, anything else inspected, all bounded.
  """
  @spec reason_text(term()) :: String.t()
  def reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, @max_reason_length)
  def reason_text(nil), do: "no reason given"

  def reason_text(exception) when is_exception(exception),
    do: reason_text("#{inspect(exception.__struct__)}: #{Exception.message(exception)}")

  def reason_text(reason), do: HandledError.bounded_inspect(reason)

  defp verb(:discard), do: "discarded the job"
  defp verb(:cancel), do: "cancelled the job"
  defp verb(:exhausted), do: "failed the job on its last attempt"
end
