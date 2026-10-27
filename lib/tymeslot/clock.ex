defmodule Tymeslot.Clock do
  @moduledoc """
  Injectable source of "now".

  Time-dependent logic — booking cut-offs, availability windows, expiry checks —
  reads the current time through this module instead of calling
  `DateTime.utc_now/0` directly. That lets tests pin "now" to a fixed instant and
  exercise boundaries (a minute before a cut-off, a DST transition, the stroke of
  midnight) deterministically, rather than racing the wall clock.

  In production `utc_now/0` is exactly `DateTime.utc_now/0`. Tests freeze it with
  `Tymeslot.Test.ClockHelpers` — the override is stored in the calling process's
  dictionary, so it is test-local and safe under `async: true` for any code that
  runs in the test process.

  That includes Oban workers as this suite tests them: `Oban.Testing.perform_job/2`
  and `Oban.drain_queue/1` both run `perform/1` in the calling process, so a job
  sees a clock the test froze. What does defeat a freeze is a genuinely spawned
  process: `Task.Supervisor.async`, which a few workers use as a timeout guard,
  or a job picked up by a live queue. Freeze those flows at the plain module the
  spawned code calls into rather than at the worker (a task follows the test's
  freeze under `:clock_follows_callers`, below; a live queue's job never does).

  A LiveView under `Phoenix.LiveViewTest` is a spawned process too, but one
  that records the test in its `$callers`. With `:clock_follows_callers` set
  (`config/test.exs` only), a process that has not frozen its own clock reads
  the first frozen one along its `$callers`, so a test can freeze the clock a
  mounted LiveView sees. The flag is read at compile time; without it the
  lookup is not compiled in and production reads only its own dictionary.

  Adoption is incremental: a namespace is "clock-managed" once all of its
  `utc_now`/`utc_today` reads go through here, at which point
  `CredoChecks.ClockUsage` guards it against regressions.
  """

  # Process-dictionary key holding a frozen `%DateTime{}`. Production never sets
  # it, so the lookup falls through to the system clock.
  @process_key :"$tymeslot_clock_frozen_at"

  @follows_callers Application.compile_env(:tymeslot, :clock_follows_callers, false)

  @doc "The process-dictionary key tests use to freeze the clock."
  @spec process_key() :: atom()
  def process_key, do: @process_key

  @doc "Current UTC time — the real system clock unless the process froze it."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case frozen_at() do
      %DateTime{} = frozen -> frozen
      _not_frozen -> DateTime.utc_now()
    end
  end

  @doc "Today's UTC date, derived from `utc_now/0` (so it honours a frozen clock)."
  @spec utc_today() :: Date.t()
  def utc_today, do: DateTime.to_date(utc_now())

  if @follows_callers do
    defp frozen_at do
      Process.get(@process_key) || callers_frozen_at(Process.get(:"$callers", []))
    end

    defp callers_frozen_at([]), do: nil

    defp callers_frozen_at([caller | callers]) do
      case Process.info(caller, :dictionary) do
        {:dictionary, dictionary} ->
          case List.keyfind(dictionary, @process_key, 0) do
            {@process_key, %DateTime{} = frozen} -> frozen
            _not_frozen -> callers_frozen_at(callers)
          end

        nil ->
          callers_frozen_at(callers)
      end
    end
  else
    defp frozen_at, do: Process.get(@process_key)
  end
end
