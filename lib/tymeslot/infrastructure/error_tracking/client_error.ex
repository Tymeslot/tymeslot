defmodule Tymeslot.Infrastructure.ErrorTracking.ClientError do
  @moduledoc """
  Decides whether an exception is a client error: bad input a visitor sent
  (an unknown route, a malformed body, a stale CSRF token, a record that does
  not exist), not a fault in the system.

  Two conditions, both required:

  1. **The status rule.** The exception is one Plug and Phoenix render as a
     4xx: `Plug.Exception.status/1` below 500. Every such exception is
     covered, including those contributed by libraries (Phoenix, Plug,
     phoenix_ecto), without a hand-kept list that drifts.
  2. **The origin rule.** It arose while serving a request or a LiveView. The
     same exception anywhere else (an Oban job, a GenServer, a Task) is a bug:
     an `Ecto.NoResultsError` in a job means the job was handed an id that
     should have existed. The origin is read from the ErrorTracker context of
     the process: its Plug and Phoenix integrations record `"request.*"` and
     `"live_view.*"` keys, its Oban integration `"job.*"` keys.

  `Tymeslot.Infrastructure.ErrorTracking.Ignorer` asks this module for
  every report, whether it comes from an integration or from
  `Tymeslot.Infrastructure.CrashReporter`, so what counts as noise is decided
  in one place.

  The Ignorer runs inside telemetry handlers, where a raise detaches the
  handler, so every function here is total: anything unexpected is logged as a warning and
  answers `false`, which means "record it".
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @request_prefixes ["request.", "live_view."]
  @job_prefix "job."

  @doc """
  Returns true when the exception, known by its module name as a string
  (`"Elixir.Phoenix.Router.NoRouteError"`, which is how ErrorTracker records
  it), maps to a 4xx response and `context` (an ErrorTracker context) shows
  it arose serving a request or a LiveView. The status is taken from the
  exception's default struct.

  An unknown module, a non-exception kind (`"exit"`, `"throw"`) or any
  failure resolving it answers `false`. Never creates an atom.
  """
  @spec client_error_kind?(String.t(), map()) :: boolean()
  def client_error_kind?(kind, context),
    do: request_origin?(context) and client_status_kind?(kind)

  @doc """
  Returns true when an ErrorTracker context was recorded while serving a
  request or a LiveView, and not while running an Oban job.
  """
  @spec request_origin?(map()) :: boolean()
  def request_origin?(context) when is_map(context) do
    keys = context |> Map.keys() |> Enum.filter(&is_binary/1)

    Enum.any?(keys, &String.starts_with?(&1, @request_prefixes)) and
      not Enum.any?(keys, &String.starts_with?(&1, @job_prefix))
  end

  def request_origin?(_context), do: false

  defp client_status_kind?(kind) when is_binary(kind) do
    module = String.to_existing_atom(kind)

    Code.ensure_loaded?(module) and function_exported?(module, :exception, 1) and
      Plug.Exception.status(module.__struct__()) < 500
  rescue
    error -> unresolved(error, kind)
  end

  defp client_status_kind?(_other), do: false

  defp unresolved(error, exception_name) do
    Logger.warning(
      "Could not tell whether an exception is a client error; treating it as a server error",
      exception: exception_name,
      error: LogFormat.reason(error.__struct__)
    )

    false
  end
end
