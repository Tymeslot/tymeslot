defmodule Tymeslot.Test.ClockHelpers do
  @moduledoc """
  Freeze `Tymeslot.Clock` to a fixed instant for deterministic time-dependent
  tests. The override lives in the current process's dictionary, so it is
  test-local and works under `async: true` for any code that runs in the test
  process (synchronous domain calls, booking validation, …).
  """

  alias Tymeslot.Clock

  @doc """
  Pins `Tymeslot.Clock.utc_now/0` to `at` for the current process. Cleared
  automatically when the test process ends; use `unfreeze_clock/0` or
  `with_frozen_clock/2` to clear it sooner.

  `at` is normalised to UTC before it is stored, so freezing with a zoned
  `DateTime` still yields a correct `utc_now/0`/`utc_today/0` — otherwise
  `utc_today/0` would return the frozen zone's local date, off by a day near
  midnight.
  """
  @spec freeze_clock(DateTime.t()) :: :ok
  def freeze_clock(%DateTime{} = at) do
    Process.put(Clock.process_key(), DateTime.shift_zone!(at, "Etc/UTC"))
    :ok
  end

  @doc "Removes any frozen clock for the current process."
  @spec unfreeze_clock() :: :ok
  def unfreeze_clock do
    Process.delete(Clock.process_key())
    :ok
  end

  @doc "Runs `fun` with the clock frozen to `at`, restoring the real clock after."
  @spec with_frozen_clock(DateTime.t(), (-> result)) :: result when result: var
  def with_frozen_clock(%DateTime{} = at, fun) when is_function(fun, 0) do
    freeze_clock(at)

    try do
      fun.()
    after
      unfreeze_clock()
    end
  end
end
