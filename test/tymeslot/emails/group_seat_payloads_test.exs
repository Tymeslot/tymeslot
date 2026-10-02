defmodule Tymeslot.Emails.GroupSeatPayloadsTest do
  @moduledoc """
  The email payloads of a group meeting: a participant's view of the slot,
  the organiser's view of one seat, and the organiser's view of the whole
  slot, and the organiser's seat email rendered from them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :bookings

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.SeatUpdateForOrganizer
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Notifications.ContentBuilder

  setup do
    organizer = insert(:user, locale: "uk", name: "Host")
    insert(:profile, user: organizer, timezone: "Europe/London")

    meeting =
      insert(:group_meeting,
        capacity: 4,
        organizer_user_id: organizer.id,
        organizer_email: "host@example.com",
        organizer_name: "Host",
        attendee_locale: "en",
        meeting_type: "Workshop",
        location_kind: "in_person",
        address_to_arrange: true
      )

    participant =
      insert(:participant,
        meeting: meeting,
        name: "Ada",
        email: "ada@example.com",
        phone: "+44 20 7946 0000",
        message: "See you there",
        locale: "de",
        timezone: "Asia/Tokyo"
      )

    _other = insert(:participant, meeting: meeting)

    %{meeting: meeting, participant: participant, seat: Recipient.from_participant(participant)}
  end

  describe "a participant's view of the slot" do
    test "is a meeting struct, so the location reads from the meeting's own kind", %{
      meeting: meeting,
      seat: seat
    } do
      assert %Tymeslot.Meetings.MeetingSchema{} = Recipient.as_seen_by(meeting, seat)

      details = AppointmentBuilder.from_meeting(meeting, seat, nil)

      # A plain-map overlay fell through to `:custom` for every participant.
      assert details.location_type == :in_person_to_arrange
    end

    test "is in the participant's own language and timezone, on their own seat's calendar entry",
         %{meeting: meeting, participant: participant, seat: seat} do
      details = AppointmentBuilder.from_meeting(meeting, seat, nil)

      assert details.attendee_locale == "de"
      assert details.attendee_timezone == "Asia/Tokyo"
      assert details.uid == participant.id
      assert details.ical_sequence == 0
    end
  end

  describe "the organiser's view of one seat" do
    test "names the participant and how full the slot is, and carries no seat link", %{
      meeting: meeting,
      participant: participant,
      seat: seat
    } do
      details = AppointmentBuilder.for_organizer_of_seat(meeting, seat)

      assert details.attendee_name == "Ada"
      assert details.attendee_email == "ada@example.com"
      assert details.attendee_phone == "+44 20 7946 0000"
      assert details.attendee_message == "See you there"
      assert details.seats_taken == 2
      assert details.capacity == 4
      assert details.cancel_url == nil
      assert details.reschedule_url == nil
      assert details.dashboard_url =~ "/dashboard/meetings"
      refute inspect(details) =~ participant.management_token
    end
  end

  describe "the organiser's view of the whole slot" do
    # The count label was rendered in whatever locale the job process had,
    # never the organiser's.
    test "names the participant count in the organiser's own language", %{meeting: meeting} do
      details = AppointmentBuilder.for_organizer_of_group(meeting, 2)

      assert details.organizer_locale == "uk"
      assert details.attendee_name == "2 учасники"
      assert details.dashboard_url =~ "/dashboard/meetings"
      assert details.cancel_url == nil
    end

    test "logs no missing-timezone warning: a group slot has no attendee of its own", %{
      meeting: meeting
    } do
      log =
        capture_log(fn ->
          AppointmentBuilder.for_organizer_of_group(meeting, 2)
          ContentBuilder.build_appointment_details(meeting)
        end)

      refute log =~ "Missing attendee_timezone"
    end
  end

  describe "the organiser's seat email" do
    setup %{meeting: meeting, seat: seat} do
      %{details: AppointmentBuilder.for_organizer_of_seat(meeting, seat)}
    end

    test "says a spot was booked, by whom, and how many are taken", %{details: details} do
      email = render_in_english(:booked, details)

      assert email.subject =~ "Spot booked: Ada"
      assert email.text_body =~ "Ada booked a spot in your group meeting."
      assert email.text_body =~ "2 of 4 spots taken"
      assert email.html_body =~ details.dashboard_url
      # The organiser's calendar holds the slot as a provider event already.
      refute Enum.any?(email.attachments, &(&1.content_type == "text/calendar"))
    end

    test "says the participant cancelled their spot, not that the meeting was cancelled", %{
      details: details
    } do
      email = render_in_english(:cancelled, details)

      assert email.subject =~ "Spot cancelled: Ada"

      assert email.text_body =~
               "Ada cancelled their spot. The meeting goes ahead for everyone else."

      refute email.text_body =~ "has been cancelled"
    end

    test "says the participant moved their spot, from when to when", %{details: details} do
      previous = DateTime.add(details.start_time_owner_tz, -1, :day)

      email = render_in_english(:moved, Map.put(details, :original_start_time_owner_tz, previous))

      assert email.subject =~ "Spot moved: Ada"
      assert email.text_body =~ ~r/Ada moved their spot from .+ to .+\./
    end

    test "says the earlier slot is free when the move emptied it", %{details: details} do
      email = render_in_english(:moved, Map.put(details, :old_slot_freed, true))

      assert email.text_body =~
               "Nobody is left at the earlier time, so that meeting has been cancelled and the time is free again."

      refute render_in_english(:moved, details).text_body =~ "Nobody is left"
    end

    test "is written in the organiser's language", %{details: details} do
      email = SeatUpdateForOrganizer.render(:booked, "host@example.com", details)

      assert email.subject =~ "Місце заброньовано: Ada"
    end
  end

  defp render_in_english(variant, details),
    do:
      SeatUpdateForOrganizer.render(variant, "host@example.com", %{
        details
        | organizer_locale: "en"
      })
end
