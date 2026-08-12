defmodule Tymeslot.Emails.Templates.AppointmentRescheduledTest do
  @moduledoc """
  Render tests for `AppointmentRescheduled`: subjects, recipients, the
  "previously scheduled for" line in each recipient's own timezone, the
  SEQUENCE-bumped ICS attachment, and the defensive reads that keep a payload
  missing optional keys from crashing the render (issue #76).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentRescheduled

  # The slot the booking moved away from: a day earlier than the
  # 2026-01-15 14:00Z default the shared helper builds.
  @original_start ~U[2026-01-14 09:00:00Z]

  defp build_reschedule_details(overrides \\ %{}) do
    build_appointment_details(
      Map.merge(
        %{
          original_date: DateTime.to_date(@original_start),
          original_start_time: @original_start,
          original_start_time_owner_tz: @original_start,
          original_start_time_attendee_tz: @original_start,
          original_end_time: ~U[2026-01-14 10:00:00Z],
          is_rescheduled: true,
          rescheduled_at: ~U[2026-01-10 08:00:00Z]
        },
        overrides
      )
    )
  end

  describe "render/3 as attendee" do
    test "subject announces the reschedule with the new date and organiser" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.subject =~ "Rescheduled"
      assert email.subject =~ details.organizer_name
      assert email.subject =~ Formatting.format_date_short(details.date, "en")
    end

    test "sets the attendee as recipient" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "states the slot the meeting moved away from" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Previously scheduled for"
      assert email.html_body =~ Formatting.format_date(@original_start, "en")
      assert email.text_body =~ "Previously scheduled for"
      assert email.text_body =~ Formatting.format_date(@original_start, "en")
    end

    test "leads with the new time, not the old one" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ Formatting.format_date(details.date, "en")
      assert email.text_body =~ Formatting.format_date(details.date, "en")
    end

    test "renders the attendee's previous time in their own timezone" do
      details =
        build_reschedule_details(%{
          original_start_time_attendee_tz: DateTime.shift_zone!(@original_start, "Asia/Tokyo"),
          original_start_time_owner_tz: DateTime.shift_zone!(@original_start, "Europe/Berlin")
        })

      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      tokyo_time =
        @original_start
        |> DateTime.shift_zone!("Asia/Tokyo")
        |> Formatting.format_time("en")

      assert email.html_body =~ tokyo_time
    end

    test "carries the reschedule and cancel links" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ details.reschedule_url
      assert email.html_body =~ details.cancel_url
    end

    test "includes the reminder summary when the payload carries one" do
      details = build_reschedule_details(%{reminders_summary: "Reminder 1 hour before"})
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Reminder 1 hour before"
      assert email.text_body =~ "Reminder 1 hour before"
    end

    # Issue #76: the reschedule payload used to be built by a different builder
    # than the one every template is written against, so an absent
    # `:reminders_summary` raised a KeyError mid-send — taking the webhook
    # dispatch and the booking confirmation screen down with it. The payload is
    # now built correctly; the template reads the key defensively so the same
    # class of mismatch degrades instead of crashing.
    test "renders when the payload carries no reminder summary" do
      details = Map.delete(build_reschedule_details(), :reminders_summary)

      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Rescheduled"
      refute email.html_body =~ "Reminders Scheduled"
    end

    test "renders without the previously-scheduled line when no original slot is given" do
      details =
        Map.drop(build_appointment_details(), [
          :original_start_time,
          :original_start_time_attendee_tz,
          :original_start_time_owner_tz
        ])

      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Rescheduled"
      refute email.html_body =~ "Previously scheduled for"
      refute email.text_body =~ "Previously scheduled for"
    end

    test "attaches an ICS whose SEQUENCE supersedes the invitation already sent" do
      details = build_reschedule_details(%{ical_sequence: 3})
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))
      assert ics.filename =~ details.uid
      assert ics.data =~ "SEQUENCE:4"
    end

    test "ICS starts at SEQUENCE 1 for a meeting that has never been updated" do
      details = Map.delete(build_reschedule_details(), :ical_sequence)
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ "SEQUENCE:1"
    end

    # Same reasoning as the confirmation ICS (issue #41): METHOD:REQUEST makes
    # scheduling-aware mail servers auto-import and auto-RSVP the attachment.
    test "attendee ICS advertises METHOD:PUBLISH with SCHEDULE-AGENT=CLIENT" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ "METHOD:PUBLISH"
      refute ics.data =~ "METHOD:REQUEST"
      assert ics.data =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
      assert ics.data =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end

    test "renders in the attendee's locale" do
      details = build_reschedule_details(%{attendee_locale: "de"})
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", details)

      assert email.subject =~ "Termin verschoben"
    end
  end

  describe "render/3 as organizer" do
    test "subject names the attendee and the new date" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", details)

      assert email.subject =~ "Rescheduled"
      assert email.subject =~ details.attendee_name
    end

    test "sets the organiser as recipient" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:organizer, "organizer@test.com", details)

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    test "shows the attendee, the previous slot, and the new one" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ details.attendee_name
      assert email.html_body =~ "Previously scheduled for"
      assert email.html_body =~ Formatting.format_date(details.date, "en")
    end

    test "renders the organiser's previous time in the organiser's timezone" do
      details =
        build_reschedule_details(%{
          original_start_time_owner_tz: DateTime.shift_zone!(@original_start, "Europe/Berlin"),
          original_start_time_attendee_tz: DateTime.shift_zone!(@original_start, "Asia/Tokyo")
        })

      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", details)

      berlin_time =
        @original_start
        |> DateTime.shift_zone!("Europe/Berlin")
        |> Formatting.format_time("en")

      assert email.html_body =~ berlin_time
    end

    # The organiser's own calendar is written directly by Tymeslot; an
    # attachment on top of that duplicates the event on iMIP-aware servers.
    test "carries no ICS attachment" do
      details = build_reschedule_details()
      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", details)

      assert Enum.find(email.attachments, &(&1.content_type =~ "text/calendar")) == nil
    end

    test "renders when the payload carries no reminder summary" do
      details = Map.delete(build_reschedule_details(), :reminders_summary)

      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Rescheduled"
    end
  end
end
