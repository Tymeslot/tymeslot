defmodule Tymeslot.Bookings.SeatEffects do
  @moduledoc """
  The effects a booked or moved group-meeting seat owes, regardless of which
  caller produced it.

  `Tymeslot.Bookings.CreateGroup` (a fresh seat booking) and
  `Tymeslot.Bookings.RescheduleSeat` (a seat moving to a new slot) both turn
  a `Tymeslot.Meetings.GroupScheduling.book_seat/3` result into cache
  invalidation, a seat-change broadcast, a calendar job, and — when the seat
  created a brand-new slot — reminders and video-room scheduling. Splitting
  that fan-out across the two callers let the reschedule path silently skip
  reminders and video-room creation for a slot it created; this module is
  the single owner of what `created_meeting?` implies, so a third caller of
  `book_seat/3` cannot half-apply the contract.

  Calendar-job scheduling is exposed rather than run automatically: each
  caller enqueues it at the point that matches its own transaction shape
  (`CreateGroup` inside `book_seat/3`'s `:on_booked` callback, atomically
  with the seat; `RescheduleSeat` after commit, since its own `:on_booked`
  is busy cancelling the old seat).
  """

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Workers.VideoRoomWorker

  require Logger

  # Booker-scoped fields that live on the `meeting_participants` row for a
  # group booking, not on the shared meeting slot.
  @booker_scoped_attrs [
    :attendee_name,
    :attendee_email,
    :attendee_message,
    :attendee_phone,
    :attendee_company,
    :attendee_timezone,
    :custom_field_answers
  ]

  @doc """
  Turns a full `Tymeslot.Bookings.Policy.build_meeting_attributes/1` map into
  a group meeting's shared-slot attrs: strips the fields that belong on the
  booker's `meeting_participants` row instead, and names the slot `title`
  rather than the booker-addressed title the builder produces (a group slot
  has no singular booker to name it after).

  Shared by `CreateGroup` (booking a fresh group slot) and `RescheduleSeat`
  (a seat move landing on a time with no live group meeting yet) so a slot
  built either way carries the same video integration, description,
  location, locale, attachments and reminder configuration.
  """
  @spec slot_attrs(map(), String.t()) :: map()
  def slot_attrs(meeting_attrs, title) do
    meeting_attrs
    |> Map.drop(@booker_scoped_attrs)
    |> Map.merge(%{title: title, summary: title})
  end

  @doc "The calendar-job action a booked/moved seat implies."
  @spec calendar_action(boolean()) :: String.t()
  def calendar_action(created_meeting?), do: if(created_meeting?, do: "create", else: "update")

  @doc "Enqueues the calendar-event job implied by a booked/moved seat."
  @spec schedule_calendar_job(map(), boolean()) :: {:ok, term()} | {:error, term()}
  def schedule_calendar_job(meeting, created_meeting?),
    do: CalendarJobs.schedule_job(meeting, calendar_action(created_meeting?))

  @doc """
  Invalidates the organiser's availability cache and broadcasts the seat
  change. Owed for every booked or moved seat, whether or not it created a
  new slot.
  """
  @spec broadcast_and_invalidate(map()) :: :ok
  def broadcast_and_invalidate(meeting) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    :ok
  end

  @doc """
  Everything a brand-new group-meeting slot owes on top of the seat itself:
  reminders scheduled once, and video-room creation kicked off for a
  provider that auto-creates rooms (or any configured provider, when the
  caller opts into `:with_video_room` explicitly, mirroring the solo
  booking path).

  Options:
    * `:announce` — the video-room job should hold the meeting's
      announcement until the room exists (or definitively fails), releasing
      it through `Tymeslot.Notifications.Events.announce_video_room_outcome/1`.
      Only the caller whose own notification IS that announcement (a fresh
      booking's first seat) should set this; a seat move already sent its
      own reschedule notification and must not have it re-announced.
    * `:with_video_room` — force room creation for any configured provider,
      not just the auto-create allow-list.

  Returns whether the caller's own confirmation should be deferred to the
  video-room worker — always `false` unless `:announce` was requested and
  the room was actually scheduled.
  """
  @spec schedule_new_slot_effects(map(), keyword()) :: boolean()
  def schedule_new_slot_effects(meeting, opts \\ []) do
    schedule_reminders(meeting)
    schedule_video_room(meeting, opts)
  end

  defp schedule_video_room(meeting, opts) do
    if wants_video_room?(meeting, opts) do
      if Keyword.get(opts, :announce, false) do
        VideoRoomWorker.schedule_video_room_creation_with_announcement(meeting.id) == :ok
      else
        VideoRoomWorker.schedule_video_room_creation(meeting.id)
        false
      end
    else
      false
    end
  end

  defp wants_video_room?(meeting, opts) do
    if Keyword.get(opts, :with_video_room, false) do
      not is_nil(meeting.video_integration_id)
    else
      Policy.auto_creates_video_room?(meeting)
    end
  end

  defp schedule_reminders(meeting) do
    case Orchestrator.schedule_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule reminder jobs for a new group slot",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end
end
