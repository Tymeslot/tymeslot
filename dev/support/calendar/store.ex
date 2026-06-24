defmodule Tymeslot.Dev.Calendar.Store do
  @moduledoc """
  In-memory rule store backing the interactive development calendar.

  Holds the active recurring `pattern` and a list of explicit busy/blocked
  `rules` that a developer mutates live from IEx via `Tymeslot.Dev.Calendar`.
  Dev-only: compiled solely under the `dev/support` path and added to the
  supervision tree only when `config :tymeslot, :dev_calendar_enabled` is true
  (set in `config/dev.exs` when `DEV_CALENDAR` / `DEV_EMPTY_CALENDAR` is set).

  An `Agent` is the right fit — low-frequency dev mutations, no hot path, no
  complex behaviour — and it is supervised per the OTP "no unsupervised
  processes" rule.
  """

  use Agent

  alias Tymeslot.Integrations.Calendar.DebugSchedule

  @type event :: %{required(:uid) => String.t(), optional(atom()) => term()}
  @type state :: %{
          pattern: DebugSchedule.pattern(),
          rules: [DebugSchedule.rule()],
          created: %{String.t() => event()}
        }

  @doc """
  Starts the store, seeding the pattern from
  `config :tymeslot, :dev_calendar_default_pattern` (defaults to `:default`).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    pattern = Application.get_env(:tymeslot, :dev_calendar_default_pattern, :default)
    Agent.start_link(fn -> %{pattern: pattern, rules: [], created: %{}} end, name: __MODULE__)
  end

  @doc "Returns the current pattern, rules and in-app created events."
  @spec snapshot() :: state()
  def snapshot, do: Agent.get(__MODULE__, & &1)

  @doc "Appends a busy/blocked rule, ignoring exact duplicates."
  @spec add_rule(DebugSchedule.rule()) :: [DebugSchedule.rule()]
  def add_rule(rule) do
    Agent.get_and_update(__MODULE__, fn state ->
      rules = if rule in state.rules, do: state.rules, else: state.rules ++ [rule]
      {rules, %{state | rules: rules}}
    end)
  end

  @doc "Replaces the active recurring pattern."
  @spec set_pattern(DebugSchedule.pattern()) :: DebugSchedule.pattern()
  def set_pattern(pattern) do
    Agent.update(__MODULE__, &%{&1 | pattern: pattern})
    pattern
  end

  @doc "Records (or replaces) an in-app created event, keyed by its uid."
  @spec put_event(event()) :: :ok
  def put_event(%{uid: uid} = event) do
    Agent.update(__MODULE__, &%{&1 | created: Map.put(&1.created, uid, event)})
  end

  @doc "Removes a previously created event by uid."
  @spec delete_event(String.t()) :: :ok
  def delete_event(uid) do
    Agent.update(__MODULE__, &%{&1 | created: Map.delete(&1.created, uid)})
  end

  @doc """
  Removes all explicit rules and in-app created events, leaving the recurring
  pattern intact.
  """
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, &%{&1 | rules: [], created: %{}})
end
