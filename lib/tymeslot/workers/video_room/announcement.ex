defmodule Tymeslot.Workers.VideoRoom.Announcement do
  @moduledoc """
  The event a video room job raises once its room exists, or once it is clear
  the room never will.

  A caller that wants every notification to carry the join link hands the
  whole announcement to `Tymeslot.Workers.VideoRoomWorker` instead of sending
  it before the room is there. Two announcements can be owed that way:

    * `:created`, a new booking. `Events.meeting_created/1` claims the event
      once per meeting, so a late room after the fallback announcement, or a
      second job for the same meeting, can never announce it twice.

    * `{:rescheduled, previous, rescheduled_to}`, a reschedule that moved the
      meeting onto a video location it has no room for yet. Nothing on the
      meeting records that a reschedule was announced, and `announced_at` is
      the booking's claim, not this one's, so the job itself has to know when
      it no longer owes the event (see `deliver/3`).

  `:none` is a job for a meeting that was already announced without a room.

  ## Carried in job args

  `Events.meeting_rescheduled/2` takes the meeting as it was before the
  reschedule, which a job cannot hold. The reschedule email reads only that
  meeting's times, so those are what the args carry, as ISO 8601 strings, next
  to the start time the reschedule moved the meeting to.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.Events

  require Logger

  @typedoc "Where the meeting was before a reschedule, as its email reads it."
  @type previous_times :: %{start_time: DateTime.t(), end_time: DateTime.t()}

  @type t :: :none | :created | {:rescheduled, previous_times(), DateTime.t()}

  @doc """
  The reschedule announcement for a meeting moved from `original` to `updated`.
  """
  @spec rescheduled(MeetingSchema.t(), MeetingSchema.t()) :: t()
  def rescheduled(%MeetingSchema{start_time: start_time}, %MeetingSchema{} = original) do
    {:rescheduled, %{start_time: original.start_time, end_time: original.end_time}, start_time}
  end

  @doc "The job args that encode `announcement`."
  @spec to_args(t()) :: map()
  def to_args(:none), do: %{"announce" => false}
  def to_args(:created), do: %{"announce" => true}

  def to_args({:rescheduled, previous, rescheduled_to}) do
    %{
      "announce" => "rescheduled",
      "previous_start_time" => DateTime.to_iso8601(previous.start_time),
      "previous_end_time" => DateTime.to_iso8601(previous.end_time),
      "start_time" => DateTime.to_iso8601(rescheduled_to)
    }
  end

  @doc """
  The announcement a job's args encode. Args predating the `announce` key, or
  carrying a value this cannot read, owe nothing.
  """
  @spec from_args(map()) :: t()
  def from_args(%{"announce" => true}), do: :created

  def from_args(%{
        "announce" => "rescheduled",
        "previous_start_time" => previous_start,
        "previous_end_time" => previous_end,
        "start_time" => rescheduled_to
      }) do
    {:rescheduled, %{start_time: parse!(previous_start), end_time: parse!(previous_end)},
     parse!(rescheduled_to)}
  end

  def from_args(_args), do: :none

  @doc "Whether the job still owes the attendees an announcement."
  @spec owed?(t()) :: boolean()
  def owed?(:none), do: false
  def owed?(_announcement), do: true

  @doc """
  Raises the announcement for `meeting`, as it now stands.

  `already_announced?` says the job's recovery has already sent this
  announcement without a room. That settles it for a reschedule, which has no
  claim of its own to consult; a booking's announcement consults its claim
  instead, which also covers a job that stopped before recording anything.

  A reschedule is not announced either when the meeting no longer starts when
  this reschedule put it: a later reschedule has moved it since, and has told
  the attendees about the meeting it is now.
  """
  @spec deliver(t(), MeetingSchema.t(), boolean()) :: :ok
  def deliver(:none, _meeting, _already_announced?), do: :ok

  def deliver(:created, meeting, _already_announced?) do
    Logger.info("Announcing the meeting now its room exists", meeting_id: meeting.id)
    Events.meeting_created(meeting)
    :ok
  end

  def deliver({:rescheduled, _previous, _rescheduled_to}, meeting, true) do
    Logger.info("Reschedule already announced without a room, not announcing it again",
      meeting_id: meeting.id
    )
  end

  def deliver({:rescheduled, previous, rescheduled_to}, meeting, false) do
    if DateTime.compare(meeting.start_time, rescheduled_to) == :eq do
      announce_reschedule(meeting, previous)
    else
      Logger.info("Meeting rescheduled again before its room existed, leaving it to that one",
        meeting_id: meeting.id
      )
    end
  end

  defp announce_reschedule(meeting, previous) do
    Logger.info("Announcing the reschedule now the meeting's room exists",
      meeting_id: meeting.id
    )

    case Events.meeting_rescheduled(meeting, previous) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send reschedule notifications from the video room job",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end
  end

  defp parse!(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    datetime
  end
end
