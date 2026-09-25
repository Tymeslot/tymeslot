defmodule Tymeslot.Infrastructure.ErrorTracking.ClientError do
  @moduledoc """
  Decides whether an exception is a client error: bad input a visitor sent
  (an unknown route, a malformed body, a stale CSRF token, a record that does
  not exist), not a fault in the system.

  The rule is the one Plug and Phoenix already use to pick the response
  status: `Plug.Exception.status/1` below 500. Every exception that renders
  a 4xx page is covered, including those contributed by libraries (Phoenix,
  Plug, phoenix_ecto), without a hand-kept list that drifts.

  Both `Tymeslot.Infrastructure.CrashReporter` (no admin alert) and
  `Tymeslot.Infrastructure.ErrorTracking.Ignorer` (not stored) ask this
  module, so the two cannot disagree about what counts as noise.

  Both callers run inside a `:logger` handler or a telemetry handler, where
  a raise detaches the handler, so every function here is total: anything
  unexpected is logged as a warning and answers `false`, which means
  "report it".
  """

  require Logger

  @doc """
  Returns true when `exception` maps to a 4xx response.
  """
  @spec client_error?(Exception.t()) :: boolean()
  def client_error?(exception) when is_exception(exception) do
    Plug.Exception.status(exception) < 500
  rescue
    error -> unresolved(error, inspect(exception.__struct__))
  end

  def client_error?(_other), do: false

  @doc """
  Like `client_error?/1`, for an exception known only by its module name as
  a string (`"Elixir.Phoenix.Router.NoRouteError"`), which is how ErrorTracker
  records it. The status is taken from the exception's default struct.

  An unknown module, a non-exception kind (`"exit"`, `"throw"`) or any
  failure resolving it answers `false`. Never creates an atom.
  """
  @spec client_error_kind?(String.t()) :: boolean()
  def client_error_kind?(kind) when is_binary(kind) do
    module = String.to_existing_atom(kind)

    Code.ensure_loaded?(module) and function_exported?(module, :exception, 1) and
      client_error?(module.__struct__())
  rescue
    error -> unresolved(error, kind)
  end

  def client_error_kind?(_other), do: false

  defp unresolved(error, exception_name) do
    Logger.warning(
      "Could not tell whether an exception is a client error; treating it as a server error",
      exception: exception_name,
      error: inspect(error.__struct__)
    )

    false
  end
end
