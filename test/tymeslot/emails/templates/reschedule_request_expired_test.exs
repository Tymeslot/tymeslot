defmodule Tymeslot.Emails.Templates.RescheduleRequestExpiredTest do
  @moduledoc """
  The host's email for a confirmed booking cancelled because the invitee's
  request to move it lapsed.
  """

  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :bookings

  alias Ecto.UUID
  alias Tymeslot.Emails.Templates.RescheduleRequestExpired
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  defp meeting do
    %Meeting{
      id: UUID.generate(),
      uid: "abc-123",
      title: "Strategy call",
      meeting_type: "Strategy call",
      start_time: ~U[2026-09-01 13:00:00Z],
      end_time: ~U[2026-09-01 13:30:00Z],
      duration: 30,
      location: "Video Call",
      organizer_name: "Sam Host",
      organizer_email: "sam@example.com",
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      attendee_timezone: "Europe/Ljubljana",
      attendee_locale: "fr",
      status: "expired",
      first_announced_at: ~U[2026-08-20 10:00:00Z]
    }
  end

  test "tells the host the booking is gone, not merely that a request lapsed" do
    email = RescheduleRequestExpired.render(meeting(), "en")

    assert email.to == [{"Sam Host", "sam@example.com"}]
    assert email.subject =~ "Reschedule request expired, booking cancelled: Alex Guest"
    assert email.html_body =~ "Your booking with Alex Guest has been cancelled."
    assert email.html_body =~ "the booking has been cancelled"
    assert email.html_body =~ "alex@example.com"
    assert email.text_body =~ "the booking has been cancelled"
  end

  test "is written in the locale it is given, not the invitee's" do
    email = RescheduleRequestExpired.render(meeting(), "de")

    assert email.subject =~ "Verschiebungsanfrage abgelaufen, Buchung storniert"
  end

  test "carries no calendar file" do
    # The host's calendar is kept by the CalDAV/OAuth write path, which the
    # release already cancelled.
    refute Enum.any?(
             meeting() |> RescheduleRequestExpired.render("en") |> Map.fetch!(:attachments),
             fn a ->
               String.ends_with?(a.filename || "", ".ics")
             end
           )
  end
end
