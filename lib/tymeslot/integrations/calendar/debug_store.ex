defmodule Tymeslot.Integrations.Calendar.DebugStore do
  @moduledoc """
  In-memory store backing the shared "debug calendar".

  Single source of truth for the debug calendar's mutable state: the active
  recurring `pattern`, a list of explicit busy/blocked `rules`, and the rich set
  of `events` created or edited through the dashboard grid (or recorded when an
  in-app booking is confirmed). The pure `DebugSchedule` generator turns the
  pattern + rules into busy blocks; `events` carry the full event payload
  (recurrence, reminders, colour, all-day, location, description, attendees) so
  they round-trip through both the booking availability path and the dashboard
  calendar grid.

  This module lives in `lib/` (not `dev/support`) so the `:debug` calendar
  provider — which is compiled in all environments — can read and write it
  without a compile-time call into a dev-only module. To keep that safe in
  `:test` and in dev without the interactive calendar enabled, the Agent is only
  started when `config :tymeslot, :dev_calendar_enabled` is true. **Every public
  function therefore guards on the process being alive**: when it is not running,
  reads return an empty snapshot and writes are no-ops that return the value the
  running path would have returned. Callers never need to know whether the store
  is up.

  An `Agent` is the right fit — low-frequency mutations, no hot path, no complex
  behaviour — and it is supervised per the OTP "no unsupervised processes" rule.
  """

  use Agent

  alias Tymeslot.Integrations.Calendar.DebugSchedule

  @typedoc """
  A rich stored event. `start_time`/`end_time` are a `Date` for all-day events
  and a `DateTime` for timed events — stored verbatim as received from the
  provider/booking layer.
  """
  @type stored_event :: %{
          required(:uid) => String.t(),
          optional(atom()) => term()
        }

  @type state :: %{
          pattern: DebugSchedule.pattern(),
          rules: [DebugSchedule.rule()],
          events: %{String.t() => stored_event()}
        }

  @empty_state %{pattern: :default, rules: [], events: %{}}

  @doc """
  Starts the store, seeding the pattern from
  `config :tymeslot, :dev_calendar_default_pattern` (defaults to `:default`).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    pattern = Application.get_env(:tymeslot, :dev_calendar_default_pattern, :default)
    Agent.start_link(fn -> %{@empty_state | pattern: pattern} end, name: __MODULE__)
  end

  @doc "Returns `true` when the store process is alive."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Returns the current pattern, rules and stored events. Returns an empty default
  snapshot when the store is not running.
  """
  @spec snapshot() :: state()
  def snapshot do
    if running?(), do: Agent.get(__MODULE__, & &1), else: @empty_state
  end

  @doc "Appends a busy/blocked rule, ignoring exact duplicates. Returns the rules."
  @spec add_rule(DebugSchedule.rule()) :: [DebugSchedule.rule()]
  def add_rule(rule) do
    if running?() do
      Agent.get_and_update(__MODULE__, fn state ->
        rules = if rule in state.rules, do: state.rules, else: state.rules ++ [rule]
        {rules, %{state | rules: rules}}
      end)
    else
      [rule]
    end
  end

  @doc "Replaces the active recurring pattern. Returns the pattern."
  @spec set_pattern(DebugSchedule.pattern()) :: DebugSchedule.pattern()
  def set_pattern(pattern) do
    if running?(), do: Agent.update(__MODULE__, &%{&1 | pattern: pattern})
    pattern
  end

  @doc "Upserts a rich stored event, keyed by its `:uid`."
  @spec put_event(stored_event()) :: :ok
  def put_event(%{uid: uid} = event) when is_binary(uid) do
    if running?(), do: Agent.update(__MODULE__, &%{&1 | events: Map.put(&1.events, uid, event)})
    :ok
  end

  @doc "Removes a stored event by uid."
  @spec delete_event(String.t()) :: :ok
  def delete_event(uid) when is_binary(uid) do
    if running?(), do: Agent.update(__MODULE__, &%{&1 | events: Map.delete(&1.events, uid)})
    :ok
  end

  @doc "Fetches a stored event by uid."
  @spec fetch_event(String.t()) :: {:ok, stored_event()} | :error
  def fetch_event(uid) when is_binary(uid) do
    Map.fetch(snapshot().events, uid)
  end

  @doc """
  Removes all explicit rules, leaving the recurring pattern and stored events
  intact.
  """
  @spec clear() :: :ok
  def clear do
    if running?(), do: Agent.update(__MODULE__, &%{&1 | rules: []})
    :ok
  end
end
