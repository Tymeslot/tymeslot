defmodule Tymeslot.CalendarGrid.QueuedWrite do
  @moduledoc """
  One of the calendar grid's queued writes of an existing event, as
  `Tymeslot.CalendarGrid.WriteQueue` keeps it: the change it carries, how it
  is made at the provider, and the result message it answers with, whichever
  process drives the queue.

  A write is a map with a `:ref` and a `:kind`: `:update` carries `:changes`
  and `:opts` for `Tymeslot.CalendarGrid.update_event/4`, `:video` a
  `:video_integration_id` for `Tymeslot.CalendarGrid.change_event_video/3`.
  """

  require Logger

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Infrastructure.Logging.LogFormat

  @typedoc "The message a write's task answers with, as `{tag, result}`."
  @type result :: {:event_update_result | :event_video_result, tuple()}

  @doc """
  The write a result message answers, and how it answered: a success, a
  video choice that changed nothing, an edit saved to sync later, or a
  failure.
  """
  @spec outcome(result()) :: {WriteQueue.ref(), WriteQueue.outcome()}
  def outcome({:event_update_result, {:ok, payload}}),
    do: {payload[:write], {:ok, payload[:updated_event]}}

  def outcome({:event_update_result, {:error, payload}}),
    do: {payload[:write], if(payload[:retry] == :queued, do: :queued, else: :failed)}

  def outcome({:event_video_result, {:unchanged, payload}}), do: {payload[:write], :unchanged}

  def outcome({:event_video_result, {:ok, payload}}),
    do: {payload[:write], {:ok, payload[:updated_event]}}

  def outcome({:event_video_result, {:error, payload}}), do: {payload[:write], :failed}

  @doc "The tag the result of `write` is sent under."
  @spec result_tag(WriteQueue.write()) :: :event_update_result | :event_video_result
  def result_tag(%{kind: :update}), do: :event_update_result
  def result_tag(%{kind: :video}), do: :event_video_result

  @doc """
  Makes `write` against `event` for `user_id` and answers with its result
  message, never raising: a crash answers as a failure.

  An update answers `{:ok, write: ref, updated_event: event}` or `{:error,
  write: ref, original_event: event, reason: reason, retry: retry}`, where
  `retry` is `:queued` when the edit is saved locally and will sync. A video
  change answers `{:ok, write: ref, original_event: event, updated_event:
  event}`, `{:unchanged, write: ref}`, or `{:error, write: ref,
  original_event: event, reason: reason}`.
  """
  @spec perform(pos_integer(), WriteQueue.write(), map()) :: tuple()
  def perform(user_id, write, event) do
    do_perform(user_id, write, event)
  catch
    kind, reason ->
      Logger.error("Calendar grid write crashed",
        write_kind: write.kind,
        kind: kind,
        error: LogFormat.reason(reason),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      crash_result(write, event)
  end

  @doc "The result `write` answers with when it crashes."
  @spec crash_result(WriteQueue.write(), map()) :: tuple()
  def crash_result(%{kind: :update, ref: ref}, event),
    do: update_failure(ref, event, :crashed, :not_queued)

  def crash_result(%{kind: :video, ref: ref}, event), do: video_failure(ref, event, :crashed)

  defp do_perform(user_id, %{kind: :update, ref: ref} = write, event) do
    case CalendarGrid.update_event(user_id, event, write.changes, write.opts) do
      {:ok, updated} -> {:ok, write: ref, updated_event: updated}
      {:error, %{reason: reason, retry: retry}} -> update_failure(ref, event, reason, retry)
    end
  end

  defp do_perform(user_id, %{kind: :video, ref: ref, video_integration_id: video_id}, event) do
    case CalendarGrid.change_event_video(user_id, event, video_id) do
      {:ok, :unchanged} ->
        {:unchanged, write: ref}

      # The event as the change wrote it, so the grid shows what the
      # calendar has and the notification diff sees exactly what the
      # attendees' invitation will carry.
      {:ok, url} ->
        {:ok,
         write: ref,
         original_event: event,
         updated_event: CalendarGrid.changed_event(user_id, event, video_id, url)}

      {:error, reason} ->
        video_failure(ref, event, reason)
    end
  end

  defp update_failure(ref, event, reason, retry),
    do: {:error, write: ref, original_event: event, reason: reason, retry: retry}

  defp video_failure(ref, event, reason),
    do: {:error, write: ref, original_event: event, reason: reason}

  @doc "`event` with the change `write` makes to it."
  @spec applied(map(), WriteQueue.write()) :: map()
  def applied(event, %{kind: :update, changes: changes}), do: Map.merge(event, changes)

  def applied(event, %{kind: :video, video_integration_id: id}),
    do: Map.put(event, :video_integration_id, id)

  @doc """
  Whether `write` is a plain edit of the event's fields: not a video change,
  nor a write to a whole series.
  """
  @spec plain_edit?(WriteQueue.write()) :: boolean()
  def plain_edit?(%{kind: :update, opts: opts} = write),
    do:
      not Map.has_key?(write, :series) and
        Keyword.get(opts, :recurrence_scope) not in [:following, :all]

  def plain_edit?(_write), do: false
end
