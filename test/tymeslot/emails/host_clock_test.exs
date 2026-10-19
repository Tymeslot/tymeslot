defmodule Tymeslot.Emails.HostClockTest do
  @moduledoc """
  A host who chose a 24-hour clock reads every email addressed to them on
  that clock, including those rendered straight from a meeting rather than
  from the appointment payload.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Ecto.UUID
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Emails.Templates.BookingApprovalRequest
  alias Tymeslot.Emails.Templates.CalendarSyncError
  alias Tymeslot.Emails.Templates.ExternalBookingChange
  alias Tymeslot.Emails.Templates.RescheduleRequestExpired
  alias Tymeslot.Emails.Templates.SeatUpdateForOrganizer
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles

  @urls %{
    review_url: "https://example.com/meeting-request/tok",
    approve_url: "https://example.com/meeting-request/tok?intent=approve",
    decline_url: "https://example.com/meeting-request/tok?intent=decline"
  }

  setup do
    host = insert(:user)
    insert(:profile, user: host, timezone: "Europe/London")
    {:ok, _prefs} = CalendarGrid.save_preferences(host.id, %{time_format: "24h"})
    %{host: host}
  end

  # 13:30 UTC on 1 September is 14:30 in London (BST).
  defp meeting(host, attrs \\ %{}) do
    struct!(
      %MeetingSchema{
        id: UUID.generate(),
        uid: "host-clock-uid",
        calendar_uid: "abc-123",
        title: "Strategy call",
        meeting_type: "Strategy call",
        start_time: ~U[2026-09-01 13:30:00Z],
        end_time: ~U[2026-09-01 14:00:00Z],
        duration: 30,
        location: "Video Call",
        organizer_user_id: host.id,
        organizer_name: "Sam Host",
        organizer_email: "sam@example.com",
        attendee_name: "Alex Guest",
        attendee_email: "alex@example.com",
        attendee_timezone: "Europe/London",
        attendee_locale: "en",
        approval_deadline_at: ~U[2026-08-30 15:00:00Z],
        status: "awaiting_approval"
      },
      attrs
    )
  end

  defp assert_24_hour(email, time) do
    for body <- [email.html_body, email.text_body] do
      assert body =~ time
      refute body =~ ~r/\d{2}:\d{2} (AM|PM)/
    end
  end

  test "for_meeting/2 resolves the host's zone and chosen clock", %{host: host} do
    assert HostClock.for_meeting(meeting(host), "en") ==
             %{timezone: "Europe/London", time_format: "24h"}
  end

  test "the approval request, its deadline and the invitee's time use the host's clock", %{
    host: host
  } do
    email = BookingApprovalRequest.render(:request, meeting(host), @urls, "en")

    assert_24_hour(email, "14:30")
    # The deadline: 15:00 UTC is 16:00 in London.
    assert email.text_body =~ "16:00"
  end

  test "the lapsed reschedule notice uses the host's clock", %{host: host} do
    email = RescheduleRequestExpired.render(meeting(host, %{status: "cancelled"}), "en")

    assert email.html_body =~ "14:30"
    refute email.html_body =~ ~r/\d{2}:\d{2} (AM|PM)/
  end

  test "the external change notice uses the host's clock", %{host: host} do
    email =
      ExternalBookingChange.render(
        meeting(host, %{status: "confirmed"}),
        "sam@example.com",
        :modified,
        "Europe/London"
      )

    assert_24_hour(email, "14:30")
  end

  test "the calendar sync failure notice uses the host's clock", %{host: host} do
    email = CalendarSyncError.render(meeting(host, %{status: "confirmed"}), :timeout)

    assert_24_hour(email, "14:30")
  end

  test "an organiser-less meeting reads in the default zone on the locale's own clock" do
    meeting = %{organizer_user_id: nil}

    assert HostClock.timezone(meeting) == Profiles.get_default_timezone()
    assert HostClock.time_format(meeting, "en") == nil
  end

  test "the seat-moved notice uses the host's clock" do
    details =
      build_appointment_details(%{
        organizer_locale: "en",
        organizer_time_format: "24h",
        start_time_owner_tz: DateTime.shift_zone!(~U[2026-09-01 13:30:00Z], "Europe/London"),
        original_start_time_owner_tz:
          DateTime.shift_zone!(~U[2026-09-01 15:30:00Z], "Europe/London"),
        old_slot_freed: false,
        capacity: 4,
        seats_taken: 2,
        dashboard_url: "https://tymeslot.example.com/dashboard/meetings"
      })

    email = SeatUpdateForOrganizer.render(:moved, "sam@example.com", details)

    assert email.html_body =~ "16:30"
    assert email.html_body =~ "14:30"
    refute email.html_body =~ ~r/\d{2}:\d{2} (AM|PM)/
  end
end
