defmodule Tymeslot.Infrastructure.ErrorTracking do
  @moduledoc """
  The application's entry point to error tracking.

  ErrorTracker stores every exception with the context of the process that
  raised it. Its own integrations contribute the request, LiveView and job
  details; this module contributes the keys that tie an occurrence to a user
  and to the log lines around it: `user_id`, `request_id` and
  `correlation_id`.

  Those keys are also Logger metadata, so `put_context/1` sets both at once.
  Setting them anywhere else, in one place and not the other, is how a log
  line and a stored exception from the same request end up disagreeing about
  who made it.
  """

  @doc """
  Sets `context` as Logger metadata and as ErrorTracker context for the
  current process.

  A `nil` value clears the key from Logger metadata and records it as `nil`
  in the error context, so resetting a key on a reused process cannot leave
  the previous request's value behind in either. ErrorTracker's context keys
  are strings (its own are `"request.path"`, `"job.args"` and so on), so the
  atom keys given here are stored as strings.
  """
  @spec put_context(keyword()) :: :ok
  def put_context(context) when is_list(context) do
    Logger.metadata(context)

    ErrorTracker.set_context(
      Map.new(context, fn {key, value} -> {Atom.to_string(key), value} end)
    )

    :ok
  end
end
