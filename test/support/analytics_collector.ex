defmodule Tymeslot.Analytics.TestCollector do
  @moduledoc """
  Records every analytics event emitted during a test run, so the suite can
  assert that every declared event actually fired at least once.

  Collection is observational: the emit functions (`TymeslotWeb.Analytics.push/3`
  and `TymeslotSaas.Analytics.track/2`) execute a `[:tymeslot, :analytics, :emitted]`
  telemetry event. This collector attaches a handler to it — so no test module
  is ever referenced from production code. A no-op until `start_link/0` runs.
  """
  use Agent

  @event [:tymeslot, :analytics, :emitted]

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts \\ []), do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  @doc "Attach the telemetry handler that feeds this collector. Call once per suite."
  @spec attach() :: :ok
  def attach do
    :telemetry.attach({__MODULE__, :emitted}, @event, &__MODULE__.handle/4, nil)
    :ok
  end

  @doc false
  @spec handle(list(atom()), map(), map(), term()) :: :ok
  def handle(@event, _measurements, %{name: name}, _config) when is_binary(name) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> Agent.update(__MODULE__, &MapSet.put(&1, name))
    end
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok

  @spec emitted() :: MapSet.t(String.t())
  def emitted do
    case Process.whereis(__MODULE__) do
      nil -> MapSet.new()
      _pid -> Agent.get(__MODULE__, & &1)
    end
  end

  @doc "Asserts every declared event in `registry` fired at least once this run."
  @spec assert_complete!(%{optional(String.t()) => [atom()]}) :: :ok
  def assert_complete!(registry) do
    missing = MapSet.difference(MapSet.new(Map.keys(registry)), emitted())

    if MapSet.size(missing) > 0 do
      raise "Analytics completeness FAILED — declared but never emitted in this run: " <>
              inspect(MapSet.to_list(missing)) <>
              "\nEither wire the missing emit, or remove it from the registry."
    end

    :ok
  end
end
