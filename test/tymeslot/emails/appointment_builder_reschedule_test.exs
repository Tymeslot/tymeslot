defmodule Tymeslot.Emails.AppointmentBuilderRescheduleTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentRescheduled

  describe "for_reschedule/2" do
    setup do
      user = insert(:user)
      insert(:profile, user: user, timezone: "Europe/Berlin")

      original =
        build(:meeting,
          organizer_user_id: user.id,
          start_time: ~U[2026-03-01 09:00:00Z],
          end_time: ~U[2026-03-01 09:30:00Z]
        )

      updated = %{
        original
        | start_time: ~U[2026-03-04 15:00:00Z],
          end_time: ~U[2026-03-04 15:30:00Z]
      }

      %{original: original, updated: updated}
    end

    test "carries the slot the meeting moved away from, in both parties' timezones", %{
      original: original,
      updated: updated
    } do
      details = AppointmentBuilder.for_reschedule(updated, original)

      assert details.is_rescheduled == true
      assert details.original_start_time == ~U[2026-03-01 09:00:00Z]
      assert details.original_end_time == ~U[2026-03-01 09:30:00Z]
      assert details.original_date == ~D[2026-03-01]
      assert details.original_start_time_owner_tz.time_zone == "Europe/Berlin"
      assert details.original_start_time_attendee_tz.time_zone == details.attendee_timezone
      assert details.start_time == ~U[2026-03-04 15:00:00Z]
    end

    test "carries the attendee join link the meeting had before the move", %{
      original: original,
      updated: updated
    } do
      original = %{original | attendee_video_url: "https://meet.example.com/room?jwt=old"}
      updated = %{updated | attendee_video_url: "https://meet.example.com/room?jwt=new"}

      details = AppointmentBuilder.for_reschedule(updated, original)

      assert details.original_attendee_video_url == "https://meet.example.com/room?jwt=old"
      assert details.attendee_video_url == "https://meet.example.com/room?jwt=new"
    end

    # Issue #76: this payload is handed straight to an email template rather
    # than to a worker that rebuilds it, so it has to satisfy the same contract
    # every other appointment email is built against. Building it from the
    # notification-side details instead left out keys the templates read, and
    # the render raised mid-reschedule.
    test "produces a payload the reschedule template can render", %{
      original: original,
      updated: updated
    } do
      details = AppointmentBuilder.for_reschedule(updated, original)

      assert %Date{} = details.date
      assert Map.has_key?(details, :reminders_summary)
      assert Map.has_key?(details, :location_type)

      attendee = AppointmentRescheduled.render(:attendee, details.attendee_email, details)
      organizer = AppointmentRescheduled.render(:organizer, details.organizer_email, details)

      assert attendee.html_body =~ "Previously scheduled for"
      assert organizer.html_body =~ "Previously scheduled for"
    end
  end
end
