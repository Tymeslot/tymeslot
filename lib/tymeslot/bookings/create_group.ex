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

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.Events

  @doc "True when the booking's meeting type holds more than one seat."
  @spec applicable?(map()) :: boolean()
  def applicable?(%{meeting_type: %MeetingTypeSchema{} = meeting_type}),
    do: MeetingTypeSchema.group?(meeting_type)

  def applicable?(_booking_data), do: false

  # Booker-scoped fields that live on the `meeting_participants` row for a
  # group booking, not on the shared meeting slot. `:attendee_locale` is
  # deliberately excluded: `MeetingSchema.group_changeset/2` still requires
  # it, so the first booker's locale seeds the (attendee-less) meeting row.
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
  Routes a group meeting type's booking through the seat transaction instead
  of the solo/paid meeting-row transaction: the slot is a shared meeting row
  and each booker becomes a `meeting_participants` record rather than the
  meeting's sole attendee.
  """
  @spec create(map(), map()) ::
          {:ok, map()} | {:error, Tymeslot.Bookings.Errors.classified_error()}
  def create(meeting_attrs, booking_data) do
    %{meeting_type: meeting_type} = booking_data

    meeting_attrs
    |> group_meeting_attrs(meeting_type)
    |> GroupScheduling.book_seat(build_seat_request(booking_data),
      on_booked: &schedule_calendar_job/1
    )
    |> map_result()
  end

  defp map_result(
         {:ok, %{meeting: meeting, participant: participant, created_meeting?: created?}}
       ) do
    Create.emit_booking_created()
    publish_seat_change(meeting)
    Events.seat_booked(meeting, participant, created?)
    {:ok, meeting}
  end

  defp map_result({:error, :slot_full}), do: {:error, :slot_taken}

  # `book_seat/3` exhausts its retry on a rare first-booker index collision
  # and surfaces the raw changeset. Its `organizer_user_id` error is worded
  # for an organiser double-booking themselves, which a group booker must
  # never see, so this collapses to the same `:slot_taken` outcome as every
  # other lost-race case; any other changeset failure is an unexpected
  # validation error.
  defp map_result({:error, %Ecto.Changeset{} = changeset}) do
    if GroupScheduling.lost_first_booker_race?(changeset) do
      {:error, :slot_taken}
    else
      {:error, :booking_failed}
    end
  end

  defp map_result({:error, reason}), do: {:error, Create.classify_error(reason)}

  defp group_meeting_attrs(meeting_attrs, meeting_type) do
    meeting_attrs
    |> Map.drop(@booker_scoped_attrs)
    |> Map.merge(%{title: meeting_type.name, summary: meeting_type.name})
  end

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

  defp schedule_calendar_job(%{meeting: meeting, created_meeting?: true}),
    do: CalendarJobs.schedule_job(meeting, "create")

  defp schedule_calendar_job(%{meeting: meeting, created_meeting?: false}),
    do: CalendarJobs.schedule_job(meeting, "update")

  # Broadcast and cache invalidation happen after the seat transaction has
  # committed, never from inside it — matches `SeatBroadcast`'s contract.
  defp publish_seat_change(meeting) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    :ok
  end
end
