defmodule Tymeslot.Emails.GroupParticipantEmailsTest do
  @moduledoc """
  The emails a group participant receives about their own spot, rendered
  from real payloads: the confirmation says the booking is a spot in a group
  session, giving the spot up is worded as the participant's own act, and a
  move is worded as their spot moving, with the old spot's calendar entry
  cancelled exactly as a solo cancellation cancels one.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :bookings

  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.EmailService.AppointmentEmails
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Meetings.Recipient

  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    organizer = insert(:user, name: "Host")
    insert(:profile, user: organizer, timezone: "Europe/London", username: "group-host")

    start_time =
      DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:group_meeting,
        capacity: 3,
        organizer_user_id: organizer.id,
        organizer_email: "host@example.com",
        organizer_name: "Host",
        meeting_type: "Workshop",
        start_time: start_time,
        end_time: DateTime.add(start_time, 3600, :second)
      )

    participant =
      insert(:participant,
        meeting: meeting,
        name: "Erin",
        email: "erin@example.com",
        locale: "en",
        timezone: "Europe/London"
      )

    details =
      AppointmentBuilder.from_meeting(meeting, Recipient.from_participant(participant), nil)

    %{organizer: organizer, meeting: meeting, participant: participant, details: details}
  end

  describe "the participant's confirmation" do
    test "says the booking is one spot in a group session", %{details: details} do
      email = AppointmentConfirmation.render(:attendee, "erin@example.com", details)

      assert email.html_body =~ "Group session: you have one of 3 spots."
      assert email.text_body =~ "Group session: you have one of 3 spots."
    end

    test "a one-to-one booking says nothing about spots", %{organizer: organizer} do
      solo =
        insert(:meeting,
          organizer_user_id: organizer.id,
          attendee_locale: "en",
          attendee_timezone: "Europe/London"
        )

      email =
        AppointmentConfirmation.render(
          :attendee,
          "solo@example.com",
          AppointmentBuilder.from_meeting(solo)
        )

      refute email.html_body =~ "Group session"
      refute email.text_body =~ "Group session"
    end
  end

  describe "the participant's own cancellation" do
    test "confirms they gave up their spot, without the host's apology", %{details: details} do
      email =
        AppointmentCancellation.render(
          :attendee,
          "erin@example.com",
          Map.put(details, :seat_given_up, true)
        )

      assert email.subject =~ "Spot cancelled - "
      assert email.subject =~ "with Host"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "given up your spot in Workshop on"
        assert body =~ "The meeting goes ahead for the others."
        assert body =~ "/group-host"
        refute body =~ "sorry"
        refute body =~ "available for booking again"
      end
    end

    test "does not say the meeting goes ahead when they were the last one on it", %{
      details: details
    } do
      email =
        AppointmentCancellation.render(
          :attendee,
          "erin@example.com",
          Map.merge(details, %{seat_given_up: true, slot_freed: true})
        )

      assert email.html_body =~ "given up your spot"
      refute email.html_body =~ "goes ahead"
      refute email.text_body =~ "goes ahead"
    end

    test "cancels the seat's calendar entry with the same file a solo cancellation sends", %{
      details: details,
      participant: participant
    } do
      seat_email =
        AppointmentCancellation.render(
          :attendee,
          "erin@example.com",
          Map.put(details, :seat_given_up, true)
        )

      solo_email = AppointmentCancellation.render(:attendee, "erin@example.com", details)

      [seat_ics] = calendar_files(seat_email)
      [solo_ics] = calendar_files(solo_email)

      assert without_stamp(seat_ics.data) == without_stamp(solo_ics.data)
      assert seat_ics.data =~ "UID:#{participant.id}"
      assert seat_ics.data =~ "STATUS:CANCELLED"
      # One revision above the invitation, so a calendar supersedes the entry.
      assert seat_ics.data =~ "SEQUENCE:1"
    end
  end

  describe "the participant's notice of a spot they moved" do
    setup %{meeting: meeting, participant: participant} do
      new_start = DateTime.add(meeting.start_time, 1, :day)

      new_meeting =
        insert(:group_meeting,
          capacity: 3,
          organizer_user_id: meeting.organizer_user_id,
          organizer_email: "host@example.com",
          organizer_name: "Host",
          meeting_type: "Workshop",
          start_time: new_start,
          end_time: DateTime.add(new_start, 3600, :second)
        )

      moved =
        insert(:participant,
          meeting: new_meeting,
          name: "Erin",
          email: "erin@example.com",
          locale: "en",
          timezone: "Europe/London"
        )

      old = AppointmentBuilder.from_meeting(meeting, Recipient.from_participant(participant), nil)

      new =
        AppointmentBuilder.from_meeting(new_meeting, Recipient.from_participant(moved), nil)

      old_event = %{
        uid: old.uid,
        ical_sequence: old.ical_sequence,
        start_time: old.start_time,
        start_time_attendee_tz: old.start_time_attendee_tz,
        end_time: old.end_time
      }

      {:ok, _sent} =
        AppointmentEmails.send_seat_reschedule_to_participant(
          "erin@example.com",
          new,
          old_event
        )

      assert_received {:email, email}
      %{email: email, moved: moved}
    end

    test "is worded as their spot moving, from the old time to the new", %{email: email} do
      assert email.subject =~ "Spot moved - "
      refute email.subject =~ "Confirmed"

      for body <- [email.html_body, email.text_body] do
        assert body =~ "spot has moved from"
        assert body =~ "Group session: you have one of 3 spots."
      end

      assert email.html_body =~ "Your spot has moved."
    end

    test "invites to the new seat's entry and cancels the old one's as a solo cancellation does",
         %{email: email, moved: moved, participant: participant} do
      assert [_new, _old] = calendar_files(email)
      new_ics = Enum.find(calendar_files(email), &(&1.data =~ "UID:#{moved.id}"))
      old_ics = Enum.find(calendar_files(email), &(&1.data =~ "UID:#{participant.id}"))

      # Both files are named as a solo booking's are: `appointment-<uid>.ics`.
      assert new_ics.filename == "appointment-#{moved.id}.ics"
      assert old_ics.filename == "appointment-#{participant.id}.ics"

      assert new_ics.data =~ "STATUS:CONFIRMED"
      # The new seat is a new entry at its own first revision, so its later
      # cancellation (one above) still supersedes it.
      assert new_ics.data =~ "SEQUENCE:0"

      assert old_ics.data =~ "METHOD:PUBLISH"
      assert old_ics.data =~ "STATUS:CANCELLED"
      assert old_ics.data =~ "SEQUENCE:1"
    end
  end

  defp calendar_files(email),
    do: Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))

  # The stamp is the moment the file was written, which two renders differ in.
  defp without_stamp(ics), do: String.replace(ics, ~r/^DTSTAMP:.*$/m, "")
end
