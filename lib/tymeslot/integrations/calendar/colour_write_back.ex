defmodule Tymeslot.Integrations.Calendar.ColourWriteBack do
  @moduledoc """
  Enqueues the best-effort provider write-back that follows a colour override
  being set on an external event, or cleared from one (a `nil` colour, which
  takes the host event back to its calendar's colour).

  Split out of `Tymeslot.Integrations.Calendar` so the context keeps to its
  public API: this is the enqueue mechanism behind `set_event_colour/3`, not a
  domain entry point of its own; outside the context only `host_colour?/1`
  is reached, through `Calendar.host_event_colour?/1`.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Workers.ColourWriteBackWorker

  @doc """
  Whether events of `provider` carry a colour of their own to write back:
  Microsoft Graph exposes no per-event colour, so Outlook's do not.
  """
  @spec host_colour?(String.t() | nil) :: boolean()
  def host_colour?("outlook"), do: false
  def host_colour?(_provider), do: true

  @doc """
  Enqueues a colour write-back for one external event; `nil` clears it.

  The worker patches only the provider's colour field; Outlook and read-only
  calendars are handled inside it. `replace: [:args]` ensures that when a user
  changes the colour again before the previous job has run, the pending job's
  args are replaced in place to carry the newest colour, a clearing included.
  A job already running is not among the unique states, so a change made
  meanwhile gets a job of its own, and a job whose write lands after a newer
  colour was chosen enqueues one more (`ColourWriteBackWorker`).

  Always returns `:ok`: a failed enqueue is logged, never surfaced, because
  the override itself is already persisted and the next sync reconciles.
  """
  @spec enqueue(pos_integer(), pos_integer(), String.t(), String.t() | nil) :: :ok
  def enqueue(user_id, integration_id, uid, colour) do
    %{"user_id" => user_id, "integration_id" => integration_id, "uid" => uid, "colour" => colour}
    |> ColourWriteBackWorker.new(replace: [:args])
    |> Oban.insert()
    |> log_enqueue_error(user_id, integration_id)

    :ok
  end

  defp log_enqueue_error({:ok, _job}, _user_id, _integration_id), do: :ok

  defp log_enqueue_error({:error, reason}, user_id, integration_id) do
    Logger.warning("Failed to enqueue colour write-back",
      user_id: user_id,
      integration_id: integration_id,
      reason: LogFormat.reason(reason)
    )
  end
end
