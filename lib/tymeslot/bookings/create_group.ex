defmodule Tymeslot.Bookings.CreateGroup do
  @moduledoc """
  Books a seat on a group meeting type (`max_participants > 1`) through
  `Tymeslot.Meetings.GroupScheduling.book_seat/3`.

  Split out from `Tymeslot.Bookings.Create` to keep that module under the
  large-module line limit. `Create` remains the sole entry point booking
  callers use: it resolves the meeting type and builds the (pre-booker)
  meeting attributes, then dispatches here once `applicable?/1` says the
  meeting type holds more than one seat.
  """

  alias Tymeslot.Bookings.Errors
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.Events

  @doc "True when the booking's meeting type holds more than one seat."
  @spec applicable?(map()) :: boolean()
  def applicable?(%{meeting_type: %MeetingTypeSchema{} = meeting_type}),
    do: MeetingTypeSchema.group?(meeting_type)

  def applicable?(_booking_data), do: false

  @doc """
  Refuses a seat on a paused group type (see `Tymeslot.MeetingTypes.GroupAccess`):
  its host has lost access to group bookings since saving it, so it takes no
  new seats, whether the first on a slot or a join. Everything else passes.

  The booking page no longer offers a paused type, so this refuses only a
  page left open from before the host lost access. The reason reads to the
  booker as the type having become unavailable, as it has.
  """
  @spec ensure_taking_seats(map()) :: :ok | {:error, :group_bookings_paused}
  def ensure_taking_seats(%{meeting_type: meeting_type}) do
    if GroupAccess.paused?(meeting_type), do: {:error, :group_bookings_paused}, else: :ok
  end

  def ensure_taking_seats(_booking_data), do: :ok

  @doc """
  The live group meeting this booking would join, or `nil` when it would
  create a new slot, be refused as full, or is not a group booking at all.

  Decided by `GroupScheduling.join_target/3`, the seat transaction's own
  joinability rule, for this booker's seats (themselves plus their guests).
  `Create` reads it to exempt a join from the booking-limit pre-check and to
  drop the meeting's own event from the calendar check; neither exemption can
  outlive the slot, because the seat transaction re-decides under its lock.
  """
  @spec join_target(map()) :: MeetingSchema.t() | nil
  def join_target(%{meeting_type: meeting_type, start_datetime: start} = booking_data) do
    if applicable?(booking_data) do
      GroupScheduling.join_target(meeting_type.id, start, 1 + length(guest_emails(booking_data)))
    end
  end

  def join_target(_booking_data), do: nil

  # `:attendee_locale` is deliberately kept off `SeatEffects.slot_attrs/2`'s
  # drop list: the first booker's locale seeds the (attendee-less) meeting
  # row, used to localise content built straight from the meeting rather
  # than through a participant recipient.

  @doc """
  Routes a group meeting type's booking through the seat transaction instead
  of the solo/paid meeting-row transaction: the slot is a shared meeting row
  and each booker becomes a `meeting_participants` record rather than the
  meeting's sole attendee.

  Every job the seat owes is enqueued inside that transaction, as
  `Tymeslot.Bookings.Create` does for a one-to-one booking: the calendar
  job, the seat's confirmation emails and integration fan-out and, for the
  seat that creates the slot, its reminders and video room. A job that
  cannot be enqueued rolls the seat back, so a seat never commits without
  the emails and jobs it owes, and no job outlives a seat that rolled back.
  The broadcast, cache invalidation and telemetry are not durable, and run
  once the seat has committed.

  Options are the same ones `Tymeslot.Bookings.Create.execute/3` accepts;
  only `:with_video_room` matters here (see `SeatEffects.schedule_new_slot_effects/2`).
  """
  @spec create(map(), map(), keyword()) :: {:ok, map()} | {:error, Errors.classified_error()}
  def create(meeting_attrs, booking_data, opts \\ []) do
    %{meeting_type: meeting_type} = booking_data

    meeting_attrs
    |> group_meeting_attrs(meeting_type)
    |> GroupScheduling.book_seat(build_seat_request(booking_data),
      on_booked: &schedule_seat_jobs(&1, opts)
    )
    |> map_result(booking_data)
  end

  defp map_result({:ok, %{meeting: meeting}}, _booking_data) do
    Telemetry.booking_created()
    SeatEffects.broadcast_and_invalidate(meeting)

    {:ok, meeting}
  end

  defp map_result({:error, :slot_full}, _booking_data), do: {:error, :slot_taken}

  # `book_seat/3` exhausts its retry on a rare first-booker index collision
  # and surfaces the raw changeset. Its `organizer_user_id` error is worded
  # for an organiser double-booking themselves, which a group booker must
  # never see, so this collapses to the same `:slot_taken` outcome as every
  # other lost-race case. A duplicate seat is worth naming: the booker has
  # this slot already, most likely from a second tab, and "try again" is the
  # wrong advice.
  defp map_result({:error, %Ecto.Changeset{} = changeset}, booking_data) do
    cond do
      GroupScheduling.lost_first_booker_race?(changeset) -> {:error, :slot_taken}
      duplicate_seat?(changeset) -> {:error, :already_booked}
      true -> {:error, Errors.classify_creation_error(changeset, booking_data)}
    end
  end

  defp map_result({:error, reason}, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}

  defp duplicate_seat?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      to_string(opts[:constraint_name] || "") == "meeting_participants_live_email_index"
    end)
  end

  # Runs inside the seat transaction (see `create/3`); any error rolls the
  # seat back. Runs again from scratch on `book_seat/3`'s retry, whose
  # rolled-back attempt took its jobs with it.
  #
  # The first seat on a slot with an API-created video provider owns the room:
  # it schedules creation and lets `VideoRoomWorker` release the confirmation
  # emails once the join link exists, exactly as the solo path does. Later
  # seats find the room already there (or on its way), so their emails go out
  # immediately and still carry the link when it lands in time. Either way
  # the job sending them is the one the seat's `confirmation_sent_at` and
  # `organizer_notified_at` markers keep from sending twice.
  defp schedule_seat_jobs(booking, opts) do
    %{meeting: meeting, participant: participant, created_meeting?: created?} = booking

    with {:ok, _job} <- SeatEffects.schedule_calendar_job(meeting, created?),
         {:ok, defer_emails?} <- schedule_new_slot_jobs(created?, meeting, opts) do
      Events.seat_booked(meeting, participant, defer_emails?: defer_emails?)
    end
  end

  defp schedule_new_slot_jobs(false, _meeting, _opts), do: {:ok, false}

  defp schedule_new_slot_jobs(true, meeting, opts),
    do: SeatEffects.schedule_new_slot_effects(meeting, Keyword.put(opts, :announce, true))

  defp group_meeting_attrs(meeting_attrs, meeting_type),
    do: SeatEffects.slot_attrs(meeting_attrs, meeting_type.name)

  defp build_seat_request(booking_data) do
    %{form_data: form_data, meeting_type: meeting_type} = booking_data

    %{
      participant: %{
        name: form_data["name"],
        email: form_data["email"],
        phone: Map.get(form_data, "phone"),
        company: Map.get(form_data, "company"),
        message: Map.get(form_data, "message"),
        timezone: booking_data.user_timezone,
        locale: booking_data.attendee_locale,
        custom_field_answers: booking_data.custom_field_answers
      },
      guest_emails: guest_emails(booking_data),
      max_participants: meeting_type.max_participants
    }
  end

  defp guest_emails(booking_data) do
    if Policy.guests_allowed?(booking_data) do
      %{form_data: form_data} = booking_data

      booking_data
      |> Map.get(:guest_emails, [])
      |> Guests.sanitize_emails(form_data["email"])
    else
      []
    end
  end
end
