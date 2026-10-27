defmodule Tymeslot.Infrastructure.BestEffort do
  @moduledoc """
  Runs one step of a best-effort sequence: a step whose failure must be
  recorded but must not stop the steps after it, such as each provider call
  made while an account is being deleted.

  An `{:error, reason}` result, a raise, an exit and a throw are each logged
  at warning level with the step name and the caller's metadata; any other
  result counts as done. Either way the step answers `:ok`, so the caller
  simply moves on to the next one.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat

  @doc """
  Runs `fun` as the step `step`, logging `message` with `metadata` if it
  fails. Always returns `:ok`.
  """
  @spec run(atom(), (-> term()), String.t(), keyword()) :: :ok
  def run(step, fun, message, metadata \\ []) when is_atom(step) and is_function(fun, 0) do
    case fun.() do
      {:error, reason} -> log_failure(step, message, metadata, reason)
      _done -> :ok
    end
  rescue
    exception ->
      log_failure(step, message, metadata, exception,
        exception: inspect(exception.__struct__),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )
  catch
    kind, reason -> log_failure(step, message, metadata, {kind, reason})
  end

  defp log_failure(step, message, metadata, reason, extra \\ []) do
    Logger.warning(
      message,
      [step: step] ++ metadata ++ [reason: LogFormat.reason(reason)] ++ extra
    )

    :ok
  end
end
