defmodule Tymeslot.Infrastructure.ErrorTracking.JobDiscarded do
  @moduledoc """
  Carries an Oban job that its worker gave up on, by returning
  `{:discard, reason}` or `{:cancel, reason}`, into ErrorTracker.

  Built by `Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes`. The message
  names the worker, the outcome and the reason; `reason` keeps the reason,
  bounded, for the occurrence's context.
  """

  alias Tymeslot.Infrastructure.ErrorTracking.HandledError

  defexception [:worker, :outcome, :reason, :message]

  @type outcome :: :discard | :cancel

  @type t :: %__MODULE__{
          worker: String.t(),
          outcome: outcome(),
          reason: String.t(),
          message: String.t()
        }

  @max_reason_length 300

  @impl Exception
  def exception({worker, outcome, reason}) when outcome in [:discard, :cancel] do
    text = reason_text(reason)

    %__MODULE__{
      worker: worker,
      outcome: outcome,
      reason: text,
      message: "#{worker} #{verb(outcome)} the job: #{text}"
    }
  end

  @doc """
  Renders a discard or cancel reason as text: a string as it is, anything
  else inspected, both bounded.
  """
  @spec reason_text(term()) :: String.t()
  def reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, @max_reason_length)
  def reason_text(nil), do: "no reason given"
  def reason_text(reason), do: HandledError.bounded_inspect(reason)

  defp verb(:discard), do: "discarded"
  defp verb(:cancel), do: "cancelled"
end
