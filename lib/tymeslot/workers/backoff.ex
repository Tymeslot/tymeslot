defmodule Tymeslot.Workers.Backoff do
  @moduledoc """
  The two shapes an Oban `backoff/1` takes here: a fixed ladder of delays, or
  a doubling delay with an optional cap.

  Each worker keeps its own numbers, chosen for its provider's quotas; only
  the arithmetic is shared, so a fix to it cannot leave a copy behind.
  """

  @doc """
  The delay for `attempt` from `steps`, in seconds. Attempts beyond the
  ladder's end reuse its last step.
  """
  @spec ladder(pos_integer(), [pos_integer(), ...]) :: pos_integer()
  def ladder(attempt, [_first | _rest] = steps) when is_integer(attempt) and attempt >= 1 do
    Enum.at(steps, min(attempt, length(steps)) - 1)
  end

  @doc """
  `base` seconds doubled for each attempt after the first, capped at `cap`.
  """
  @spec exponential(pos_integer(), pos_integer(), pos_integer() | :infinity) :: pos_integer()
  def exponential(attempt, base, cap \\ :infinity)
      when is_integer(attempt) and attempt >= 1 do
    delay = base * Integer.pow(2, attempt - 1)
    if cap == :infinity, do: delay, else: min(delay, cap)
  end
end
