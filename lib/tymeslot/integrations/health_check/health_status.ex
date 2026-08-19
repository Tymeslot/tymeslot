defmodule Tymeslot.Integrations.HealthCheck.HealthStatus do
  @moduledoc """
  Canonical set of integration health status values.

  Single source of truth for the `healthy | degraded | unhealthy` value set
  stored in `integration_health_states.status`. Every reader and writer of
  that column goes through this module rather than repeating the literal
  set: a status added or renamed in only one of several scattered copies
  compiles fine and silently never matches.
  """

  @type t :: :healthy | :degraded | :unhealthy

  @values [:healthy, :degraded, :unhealthy]
  @by_string Map.new(@values, &{Atom.to_string(&1), &1})

  @doc "The valid status atoms."
  @spec values() :: [t()]
  def values, do: @values

  @doc "The valid status values in their stored string form."
  @spec strings() :: [String.t()]
  def strings, do: Map.keys(@by_string)

  @doc "Converts a status atom to its stored string form."
  @spec to_db_value(t()) :: String.t()
  def to_db_value(status) when status in @values, do: Atom.to_string(status)

  @doc "Parses a stored string into its status atom, or `:error` if unrecognised."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(str) when is_binary(str), do: Map.fetch(@by_string, str)
end
