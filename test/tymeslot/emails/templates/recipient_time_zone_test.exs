defmodule Tymeslot.Emails.Templates.RecipientTimeZoneTest do
  @moduledoc """
  Each recipient of a booking's emails reads the meeting's time on their own
  clock, in both parts of the email: the organiser in the organiser's zone,
  the booker and their guests in the booker's. The HTML card and the plain-text
  body state the same time, labelled with the same zone.

  The organiser is in Berlin and the booker in Kolkata, a half-hour offset, so
  a time taken from the wrong side cannot coincide with the right one.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled,
    MeetingEndChanged,
    SeatUpdateForOrganizer
  }

  # 09:00 UTC on 15 January: 10:00 in Berlin (CET), 14:30 in Kolkata (IST).
  @start ~U[2026-01-15 09:00:00Z]

  @organizer_time "10:00 CET (Europe/Berlin)"
  @attendee_time_en "02:30 PM IST (Asia/Kolkata)"
  @attendee_time_de "14:30 IST (Asia/Kolkata)"

  defp details(overrides \\ %{}) do
    build_appointment_details(
      Map.merge(
        %{
          start_time: @start,
          end_time: DateTime.add(@start, 60, :minute),
          start_time_owner_tz: DateTime.shift_zone!(@start, "Europe/Berlin"),
          start_time_attendee_tz: DateTime.shift_zone!(@start, "Asia/Kolkata"),
          attendee_timezone: "Asia/Kolkata",
          organizer_locale: "en",
          organizer_time_format: "24h",
          guest_name: "Greg Guest"
        },
        overrides
      )
    )
  end

  # The time line is the same in both parts; the HTML escapes nothing in it.
  defp assert_reads(email, time) do
    assert email.html_body =~ time
    assert email.text_body =~ "Time: #{time}"
  end

  for template <- [
        AppointmentConfirmation,
        AppointmentReminder,
        AppointmentCancellation,
        AppointmentRescheduled
      ] do
    describe "#{inspect(template)}" do
      test "the organiser reads their own time and zone in HTML and text" do
        email = unquote(template).render(:organizer, "organizer@example.com", details())

        assert_reads(email, @organizer_time)
        refute email.text_body =~ "Asia/Kolkata"
        refute email.text_body =~ "IST"
      end

      test "the booker reads their own time and zone in HTML and text" do
        email = unquote(template).render(:attendee, "attendee@example.com", details())

        assert_reads(email, @attendee_time_en)
        refute email.text_body =~ "Europe/Berlin"
      end

      test "a guest reads the booker's time and zone in HTML and text" do
        email = unquote(template).render(:guest, "greg@example.com", details())

        assert_reads(email, @attendee_time_en)
      end

      test "a German booker reads their time on their own clock" do
        email =
          unquote(template).render(
            :attendee,
            "attendee@example.com",
            details(%{attendee_locale: "de"})
          )

        assert email.html_body =~ @attendee_time_de
        assert email.text_body =~ "Uhrzeit: #{@attendee_time_de}"
      end
    end
  end

  test "a payload without the booker's zone still names the zone their time is in" do
    email =
      AppointmentCancellation.render(
        :attendee,
        "attendee@example.com",
        Map.delete(details(), :attendee_timezone)
      )

    assert email.html_body =~ "02:30 PM IST (Asia/Kolkata)"
    assert email.text_body =~ "Time: 02:30 PM IST (Asia/Kolkata)\n"
  end

  describe "a meeting on different days for the two sides" do
    # 23:30 UTC on Thursday 15 January: 05:00 on Friday 16 January in
    # Kolkata, 18:30 on Thursday 15 January in New York.
    defp across_midnight do
      start = ~U[2026-01-15 23:30:00Z]

      details(%{
        date: ~D[2026-01-15],
        start_time: start,
        end_time: DateTime.add(start, 60, :minute),
        start_time_owner_tz: DateTime.shift_zone!(start, "America/New_York"),
        start_time_attendee_tz: DateTime.shift_zone!(start, "Asia/Kolkata"),
        attendee_timezone: "Asia/Kolkata"
      })
    end

    for template <- [
          AppointmentConfirmation,
          AppointmentReminder,
          AppointmentCancellation,
          AppointmentRescheduled
        ] do
      test "#{inspect(template)} gives the booker their own day" do
        email = unquote(template).render(:attendee, "attendee@example.com", across_midnight())

        assert email.html_body =~ "16 January 2026"
        assert email.html_body =~ "FRIDAY"
        assert email.text_body =~ "Date: 16 January 2026"
      end

      test "#{inspect(template)} gives the organiser their own day" do
        email = unquote(template).render(:organizer, "organizer@example.com", across_midnight())

        assert email.html_body =~ "15 January 2026"
        assert email.html_body =~ "THURSDAY"
        assert email.text_body =~ "Date: 15 January 2026"
      end

      test "#{inspect(template)} gives an organiser ahead of UTC their own day" do
        start = ~U[2026-01-15 23:30:00Z]

        swapped = %{
          across_midnight()
          | start_time_owner_tz: DateTime.shift_zone!(start, "Asia/Kolkata"),
            start_time_attendee_tz: DateTime.shift_zone!(start, "America/New_York"),
            attendee_timezone: "America/New_York"
        }

        email = unquote(template).render(:organizer, "organizer@example.com", swapped)

        assert email.html_body =~ "16 January 2026"
        assert email.html_body =~ "FRIDAY"
        assert email.text_body =~ "Date: 16 January 2026"
      end
    end
  end

  describe "subject lines" do
    # 23:30 UTC on 15 January: 16 January in Kolkata (the booker and their
    # guests), still 15 January in New York (the organiser). The reminder's
    # subject names no date.
    for template <- [AppointmentConfirmation, AppointmentCancellation, AppointmentRescheduled] do
      test "#{inspect(template)} names each recipient's own day" do
        start = ~U[2026-01-15 23:30:00Z]

        details =
          details(%{
            date: ~D[2026-01-15],
            start_time: start,
            start_time_owner_tz: DateTime.shift_zone!(start, "America/New_York"),
            start_time_attendee_tz: DateTime.shift_zone!(start, "Asia/Kolkata")
          })

        for {role, day, not_day} <- [
              {:attendee, "16 Jan", "15 Jan"},
              {:guest, "16 Jan", "15 Jan"},
              {:organizer, "15 Jan", "16 Jan"}
            ] do
          email = unquote(template).render(role, "someone@example.com", details)

          assert email.subject =~ day, "#{role}: #{email.subject}"
          refute email.subject =~ not_day
        end
      end
    end
  end

  describe "a meeting on the day the clocks change" do
    # Europe moves to summer time at 01:00 UTC on 29 March 2026: 09:00 UTC
    # that day is 11:00 CEST in Berlin, not 10:00 CET as a fixed offset
    # taken from the winter would make it.
    test "the organiser reads the summer-time clock in both parts" do
      start = ~U[2026-03-29 09:00:00Z]

      details =
        details(%{
          date: ~D[2026-03-29],
          start_time: start,
          start_time_owner_tz: DateTime.shift_zone!(start, "Europe/Berlin"),
          start_time_attendee_tz: DateTime.shift_zone!(start, "Asia/Kolkata")
        })

      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert_reads(email, "11:00 CEST (Europe/Berlin)")
      refute email.text_body =~ "CET (Europe/Berlin)"
    end
  end

  describe "an organiser in UTC" do
    test "reads the time without a zone name in brackets" do
      details =
        details(%{
          start_time_owner_tz: DateTime.shift_zone!(@start, "Etc/UTC")
        })

      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert_reads(email, "09:00 UTC")
      refute email.text_body =~ "(Etc/UTC)"
      refute email.html_body =~ "(Etc/UTC)"
    end
  end

  describe "the other emails built from a booking payload" do
    test "SeatUpdateForOrganizer gives the organiser their own time" do
      details =
        Map.merge(details(), %{
          capacity: 3,
          seats_taken: 2,
          dashboard_url: "https://example.com/dashboard/meetings"
        })

      email = SeatUpdateForOrganizer.render(:booked, "organizer@example.com", details)

      assert_reads(email, @organizer_time)
      refute email.text_body =~ "Asia/Kolkata"
    end

    for role <- [:attendee, :guest] do
      test "MeetingEndChanged gives the #{role} the booker's time" do
        details =
          Map.merge(details(), %{
            end_time: DateTime.add(@start, 90, :minute),
            original_end_time: DateTime.add(@start, 60, :minute),
            duration: 90
          })

        email = MeetingEndChanged.render(unquote(role), "someone@example.com", details)

        assert_reads(email, @attendee_time_en)
        refute email.text_body =~ "Europe/Berlin"
      end
    end
  end

  describe "the time a rescheduled meeting moved from" do
    # Previously 08:00 UTC on 14 January: 09:00 in Berlin, 13:30 in Kolkata.
    defp moved do
      previous = ~U[2026-01-14 08:00:00Z]

      details(%{
        original_start_time: previous,
        original_start_time_owner_tz: DateTime.shift_zone!(previous, "Europe/Berlin"),
        original_start_time_attendee_tz: DateTime.shift_zone!(previous, "Asia/Kolkata")
      })
    end

    test "reads on the organiser's own clock, zone named, in both parts" do
      email = AppointmentRescheduled.render(:organizer, "organizer@example.com", moved())
      previously = "14 January 2026 at 09:00 CET (Europe/Berlin)"

      assert email.html_body =~ previously
      assert email.text_body =~ "Previously scheduled for: #{previously}"
    end

    test "reads on the booker's clock, zone named, in both parts" do
      email = AppointmentRescheduled.render(:attendee, "attendee@example.com", moved())
      previously = "14 January 2026 at 01:30 PM IST (Asia/Kolkata)"

      assert email.html_body =~ previously
      assert email.text_body =~ "Previously scheduled for: #{previously}"
    end

    test "names both ends of a moved spot with their zone" do
      email =
        AppointmentRescheduled.render(
          :attendee,
          "attendee@example.com",
          Map.put(moved(), :seat_move, true)
        )

      assert email.text_body =~
               "from 14 January 2026 at 01:30 PM IST (Asia/Kolkata) to 15 January 2026 at 02:30 PM IST (Asia/Kolkata)"
    end
  end
end
