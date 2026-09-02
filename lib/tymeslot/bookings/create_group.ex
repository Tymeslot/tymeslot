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
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.Events

  @doc "True when the booking's meeting type holds more than one seat."
  @spec applicable?(map()) :: boolean()
  def applicable?(%{meeting_type: %MeetingTypeSchema{} = meeting_type}),
    do: MeetingTypeSchema.group?(meeting_type)

  def applicable?(_booking_data), do: false

  # `:attendee_locale` is deliberately kept off `SeatEffects.slot_attrs/2`'s
  # drop list: the first booker's locale seeds the (attendee-less) meeting
  # row, used to localise content built straight from the meeting rather
  # than through a participant recipient.

  @doc """
  Routes a group meeting type's booking through the seat transaction instead
  of the solo/paid meeting-row transaction: the slot is a shared meeting row
  and each booker becomes a `meeting_participants` record rather than the
  meeting's sole attendee.

  Options are the same ones `Tymeslot.Bookings.Create.execute/3` accepts;
  only `:with_video_room` matters here (see `SeatEffects.schedule_new_slot_effects/2`).
  """
  @spec create(map(), map(), keyword()) :: {:ok, map()} | {:error, Errors.classified_error()}
  def create(meeting_attrs, booking_data, opts \\ []) do
    %{meeting_type: meeting_type} = booking_data

    meeting_attrs
    |> group_meeting_attrs(meeting_type)
    |> GroupScheduling.book_seat(build_seat_request(booking_data),
      on_booked: &schedule_calendar_job/1
    )
    |> map_result(opts)
  end

  defp map_result(
         {:ok, %{meeting: meeting, participant: participant, created_meeting?: created?}},
         opts
       ) do
    Telemetry.booking_created()
    SeatEffects.broadcast_and_invalidate(meeting)

    defer_emails? = created? and schedule_new_slot_effects(meeting, opts)

    Events.seat_booked(meeting, participant, defer_emails?: defer_emails?)

    {:ok, meeting}
  end

  defp map_result({:error, :slot_full}, _opts), do: {:error, :slot_taken}

  # `book_seat/3` exhausts its retry on a rare first-booker index collision
  # and surfaces the raw changeset. Its `organizer_user_id` error is worded
  # for an organiser double-booking themselves, which a group booker must
  # never see, so this collapses to the same `:slot_taken` outcome as every
  # other lost-race case. A duplicate seat is worth naming: the booker has
  # this slot already, most likely from a second tab, and "try again" is the
  # wrong advice.
  defp map_result({:error, %Ecto.Changeset{} = changeset}, _opts) do
    cond do
      GroupScheduling.lost_first_booker_race?(changeset) -> {:error, :slot_taken}
      duplicate_seat?(changeset) -> {:error, :already_booked}
      true -> {:error, :booking_failed}
    end
  end

  defp map_result({:error, reason}, _opts), do: {:error, Errors.classify_error(reason)}

  defp duplicate_seat?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      to_string(opts[:constraint_name] || "") == "meeting_participants_live_email_index"
    end)
  end

  # The first seat on a slot with an API-created video provider owns the room:
  # it schedules creation and lets `VideoRoomWorker` release the confirmation
  # emails once the join link exists, exactly as the solo path does. Later
  # seats find the room already there (or on its way), so their emails go out
  # immediately and still carry the link when it lands in time.
  #
  # Returns whether this seat's confirmation is now the video worker's job.
  # A failure to schedule only means the emails go without a link — never
  # that the seat is lost.
  defp schedule_new_slot_effects(meeting, opts) do
    SeatEffects.schedule_new_slot_effects(meeting, Keyword.put(opts, :announce, true))
  end

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

  defp schedule_calendar_job(%{meeting: meeting, created_meeting?: created?}),
    do: SeatEffects.schedule_calendar_job(meeting, created?)
end
