defmodule Tymeslot.Emails.Templates.RequestEmailsTimeLineTest do
  @moduledoc """
  The plain-text part of the booking-request emails states the time, in the
  recipient's zone and worded as the HTML card words it, rather than only a
  date and a zone name.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Emails.HostClock

  alias Tymeslot.Emails.Templates.{
    BookingRequestOutcome,
    BookingRequestReceived,
    RescheduleRequest,
    RescheduleRequestExpired
  }

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  # 13:00 UTC on 1 September 2026 is 15:00 CEST in Ljubljana.
  @booker_time "03:00 PM CEST (Europe/Ljubljana)"

  defp meeting(attrs \\ %{}) do
    struct!(
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
        attendee_locale: "en",
        status: "pending",
        first_announced_at: ~U[2026-08-20 10:00:00Z]
      },
      attrs
    )
  end

  # The text's time line, which the HTML card must show word for word.
  defp time_line(email) do
    [_all, time] = Regex.run(~r/^Time: (.+)$/m, email.text_body)
    assert email.html_body =~ time
    time
  end

  test "BookingRequestReceived states the booker's time" do
    assert time_line(BookingRequestReceived.render(meeting())) == @booker_time
  end

  test "BookingRequestOutcome states the booker's time" do
    assert time_line(BookingRequestOutcome.render(:declined, meeting())) == @booker_time
  end

  test "RescheduleRequest states the booker's time" do
    meeting =
      insert(:meeting,
        start_time: ~U[2025-03-15 14:00:00Z],
        attendee_timezone: "America/New_York",
        attendee_locale: "en"
      )

    # 14:00 UTC on 15 March 2025 is 10:00 EDT in New York.
    assert time_line(RescheduleRequest.render(meeting)) == "10:00 AM EDT (America/New_York)"
  end

  test "RescheduleRequestExpired states the host's time, in the host's zone" do
    meeting = meeting(%{status: "expired"})
    host_zone = HostClock.for_meeting(meeting, "en").timezone
    host_start = DateTime.shift_zone!(meeting.start_time, host_zone)

    time = time_line(RescheduleRequestExpired.render(meeting, "en"))

    assert time =~ Calendar.strftime(host_start, "%I:%M %p %Z")
    refute time =~ "Europe/Ljubljana"
  end
end
