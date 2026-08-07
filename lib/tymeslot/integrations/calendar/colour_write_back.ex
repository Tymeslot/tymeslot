defmodule Tymeslot.Integrations.Calendar.ColourWriteBack do
  @moduledoc """
  Enqueues the best-effort provider write-back that follows a colour override
  being set on an external event.

  Split out of `Tymeslot.Integrations.Calendar` so the context keeps to its
  public API: this is the enqueue mechanism behind `set_event_colour/3`, not a
  a domain entry point of its own, and nothing outside the context calls it.
  """

  require Logger

  alias Tymeslot.Workers.ColourWriteBackWorker

  @doc """
  Enqueues a colour write-back for one external event.

  The worker patches only the provider's colour field; Outlook and read-only
  calendars are handled inside it. `replace: [:args]` ensures that when a user
  changes the colour again before the previous job has run, the pending job's
  args are replaced in place to carry the newest colour — without it, `unique`
  alone would keep the *older* job (and its stale colour) and silently drop
  the newer enqueue.

  Always returns `:ok`: a failed enqueue is logged, never surfaced, because
  the override itself is already persisted and the next sync reconciles.
  """
  @spec enqueue(pos_integer(), pos_integer(), String.t(), String.t()) :: :ok
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
      reason: inspect(reason)
    )
  end
end
