defmodule Tymeslot.Emails.Templates.AttendeeJoinLinkTest do
  @moduledoc """
  A booker always has a way into a video meeting: when no participant link
  was minted for them, every email addressed to them carries the room URL
  instead, in both the HTML and the plain-text part.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled,
    MeetingEndChanged
  }

  @room "https://meet.example.com/the-room"

  defp without_participant_link do
    build_appointment_details(%{
      meeting_url: @room,
      attendee_video_url: nil,
      original_end_time: ~U[2026-01-15 14:30:00Z]
    })
  end

  for template <- [
        AppointmentConfirmation,
        AppointmentReminder,
        AppointmentRescheduled,
        MeetingEndChanged
      ] do
    test "#{inspect(template)} gives the booker the room URL" do
      email =
        unquote(template).render(:attendee, "attendee@example.com", without_participant_link())

      assert email.html_body =~ ~s(href="#{@room}")
      assert email.text_body =~ @room
    end
  end
end
