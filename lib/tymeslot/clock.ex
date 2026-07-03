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
  runs in the test process. Code that reads the clock in a spawned process (an
  Oban job, a Task) will not see a frozen value; freeze such flows at their own
  boundary instead.

  Adoption is incremental: a namespace is "clock-managed" once all of its
  `utc_now`/`utc_today` reads go through here, at which point
  `CredoChecks.ClockUsage` guards it against regressions.
  """

  # Process-dictionary key holding a frozen `%DateTime{}`. Production never sets
  # it, so the lookup falls through to the system clock.
  @process_key :"$tymeslot_clock_frozen_at"

  @doc "The process-dictionary key tests use to freeze the clock."
  @spec process_key() :: atom()
  def process_key, do: @process_key

  @doc "Current UTC time — the real system clock unless the process froze it."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Process.get(@process_key) do
      %DateTime{} = frozen -> frozen
      _not_frozen -> DateTime.utc_now()
    end
  end

  @doc "Today's UTC date, derived from `utc_now/0` (so it honours a frozen clock)."
  @spec utc_today() :: Date.t()
  def utc_today, do: DateTime.to_date(utc_now())
end
