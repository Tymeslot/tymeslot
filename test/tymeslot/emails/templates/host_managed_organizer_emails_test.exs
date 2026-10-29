defmodule Tymeslot.Emails.Templates.HostManagedOrganizerEmailsTest do
  @moduledoc """
  The host's own emails about a meeting they manage (one confirmed from a
  poll): nobody booked it, so they name the meeting and list its guests
  rather than presenting the guest in its attendee fields as the booker.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled
  }

  alias Tymeslot.Meetings.Guests

  setup do
    user = insert(:user)
    insert(:profile, user: user)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        title: "Board meeting",
        attendee_name: "Ada Lovelace",
        attendee_email: "ada@example.com",
        status: :confirmed,
        managed_by_host: true,
        meeting_type_id: nil
      )

    {:ok, _guests} =
      Guests.create_for_meeting(meeting.id, ["ada@example.com", "bob@example.com"], :organizer)

    %{user: user, meeting: meeting}
  end

  # Nothing the host is sent names the guest in the attendee fields as the
  # one who booked, or offers the public links refused for such a meeting.
  defp assert_about_the_meeting(email, meeting) do
    for body <- [email.subject, email.html_body, email.text_body] do
      refute body =~ "Ada Lovelace"
      refute body =~ meeting.uid
    end

    assert email.reply_to == nil
    assert email.text_body =~ "ada@example.com"
    assert email.text_body =~ "bob@example.com"
  end

  test "the confirmation says the poll is confirmed and lists the guests", %{meeting: meeting} do
    details =
      meeting |> AppointmentBuilder.from_meeting() |> AppointmentBuilder.organizer_copy(meeting)

    email = AppointmentConfirmation.render(:organizer, meeting.organizer_email, details)

    assert email.subject =~ "Poll confirmed: Board meeting"
    assert email.html_body =~ "Your poll is confirmed"
    assert email.html_body =~ "/dashboard/meetings"
    refute email.subject =~ "New Appointment"
    assert_about_the_meeting(email, meeting)
  end

  test "the reminder is named after the meeting", %{meeting: meeting} do
    details =
      meeting
      |> AppointmentBuilder.from_meeting(%{value: 30, unit: "minutes"})
      |> AppointmentBuilder.organizer_copy(meeting)

    email = AppointmentReminder.render(:organizer, meeting.organizer_email, details)

    assert email.subject =~ "Board meeting in"
    refute email.subject =~ "Meeting with"
    assert_about_the_meeting(email, meeting)
  end

  test "the cancellation is named after the meeting and its guests are told",
       %{meeting: meeting} do
    details =
      meeting |> AppointmentBuilder.from_meeting() |> AppointmentBuilder.organizer_copy(meeting)

    email = AppointmentCancellation.render(:organizer, meeting.organizer_email, details)

    assert email.subject =~ "Board meeting"
    assert email.text_body =~ "Board meeting has been cancelled."
    assert email.text_body =~ "Your guests have been notified of the cancellation."
    assert_about_the_meeting(email, meeting)
  end

  test "a move says the host moved it and its guests are told", %{meeting: meeting} do
    details =
      meeting
      |> AppointmentBuilder.for_reschedule(%{
        start_time: DateTime.add(meeting.start_time, -1, :day),
        end_time: DateTime.add(meeting.end_time, -1, :day),
        attendee_video_url: nil
      })
      |> AppointmentBuilder.organizer_copy(meeting)

    email = AppointmentRescheduled.render(:organizer, meeting.organizer_email, details)

    assert email.subject =~ "Board meeting"
    assert email.text_body =~ "You moved this meeting."
    assert email.text_body =~ "Your guests have been notified of the new time."
    assert_about_the_meeting(email, meeting)
  end

  test "a meeting with a booker keeps its organiser copy as it was" do
    meeting = insert(:meeting, attendee_name: "Grace Hopper")
    details = AppointmentBuilder.from_meeting(meeting)

    assert AppointmentBuilder.organizer_copy(details, meeting) == details
  end
end
