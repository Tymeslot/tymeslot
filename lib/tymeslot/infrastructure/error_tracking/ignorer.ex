defmodule Tymeslot.Infrastructure.ErrorTracking.Ignorer do
  @moduledoc """
  Keeps client-error (4xx) exceptions out of ErrorTracker.

  The list is `config :tymeslot, :ignored_exceptions`, the same one
  `Tymeslot.Infrastructure.CrashReporter` uses to decide which crashes never
  raise an admin alert, so the two cannot disagree about what counts as noise.
  """

  @behaviour ErrorTracker.Ignorer

  alias ErrorTracker.Error

  @impl ErrorTracker.Ignorer
  def ignore?(%Error{kind: kind}, _context) do
    # ErrorTracker records an exception's kind as `to_string(module)`
    # ("Elixir.Ecto.NoResultsError"). Read at runtime, as CrashReporter does,
    # so both always see the same list.
    :tymeslot
    |> Application.get_env(:ignored_exceptions, [])
    |> Enum.any?(&(to_string(&1) == kind))
  end
end
