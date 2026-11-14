defmodule Tymeslot.Emails.Templates.SeriesConfirmationTest do
  @moduledoc """
  Render tests for `SeriesConfirmation`: the booker's and the organiser's
  copy of the one confirmation a booked series sends.
  """

  use ExUnit.Case, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.SeriesConfirmation

  defp ics(email), do: Enum.find(email.attachments, &(&1.content_type == "text/calendar"))

  describe "render/3 as attendee" do
    test "names the session count and the host in the subject" do
      email = SeriesConfirmation.render(:attendee, "ada@example.com", build_series_details(3))

      assert email.subject == "Your 3 sessions with John Organizer are booked"
      assert email.to == [{"Jane Attendee", "ada@example.com"}]
    end

    test "lists every session with its own links and join link" do
      details = build_series_details(3)
      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      for session <- details.sessions do
        assert email.text_body =~ "Session #{session.position} of 3"
        assert email.text_body =~ session.reschedule_url
        assert email.text_body =~ session.cancel_url
        assert email.text_body =~ session.attendee_video_url
        assert email.html_body =~ session.cancel_url
      end
    end

    test "states the rhythm in the attendee's timezone" do
      email = SeriesConfirmation.render(:attendee, "ada@example.com", build_series_details(3))

      # The first session is 14:00 UTC on Thursday 15 January 2026, 09:00 in New York.
      assert email.text_body =~ "Every week on Thursday at 09:00 AM"
    end

    test "links the page managing every session" do
      details = build_series_details(2)
      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      assert email.html_body =~ details.series_url
      assert email.text_body =~ "Manage all sessions: #{details.series_url}"
    end

    test "leaves the series link out when there is none" do
      email =
        SeriesConfirmation.render(
          :attendee,
          "ada@example.com",
          build_series_details(2, %{series_url: nil})
        )

      refute email.text_body =~ "Manage all sessions"
      refute email.html_body =~ "Manage all sessions"
    end

    test "promises the join link in the reminder while a room is being made" do
      details =
        build_series_details(2, %{
          session: %{video_pending: true, meeting_url: nil, attendee_video_url: nil}
        })

      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      assert length(String.split(email.text_body, "The join link will be in your reminder.")) ==
               3
    end

    test "attaches one calendar file with every session" do
      details = build_series_details(3)
      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      assert ics(email).filename == "series-#{details.series.uid}.ics"
      assert length(Regex.scan(~r/^BEGIN:VEVENT/m, ics(email).data)) == 3
    end

    test "shows the total of a paid series" do
      details = build_series_details(4, %{total: %{cents: 20_000, currency: "eur"}})
      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      assert email.text_body =~ "Total paid: €200.00"
    end

    test "writes the total the way the reader's language does" do
      details =
        build_series_details(4, %{
          attendee_locale: "de",
          total: %{cents: 123_450, currency: "eur"}
        })

      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      assert email.text_body =~ "1.234,50 €"
      refute email.text_body =~ "€1,234.50"
    end

    test "shows no total for a free series" do
      email = SeriesConfirmation.render(:attendee, "ada@example.com", build_series_details(2))
      refute email.text_body =~ "Total paid"
    end

    test "a flexible series names no rhythm" do
      details = build_series_details(2)
      details = %{details | series: %{details.series | mode: :flexible, frequency: nil}}
      email = SeriesConfirmation.render(:attendee, "ada@example.com", details)

      refute email.text_body =~ "Every "
    end
  end

  describe "render/3 as organizer" do
    test "names the booker and the session count" do
      email =
        SeriesConfirmation.render(:organizer, "organizer@example.com", build_series_details(3))

      assert email.subject == "Jane Attendee booked 3 sessions"
      assert email.to == [{"John Organizer", "organizer@example.com"}]
    end

    test "links each session in the dashboard, not the booker's links" do
      details = build_series_details(2)
      email = SeriesConfirmation.render(:organizer, "organizer@example.com", details)

      for session <- details.sessions do
        assert email.text_body =~ session.dashboard_url
        refute email.text_body =~ session.cancel_url
        assert email.text_body =~ session.organizer_video_url
      end
    end

    test "carries no calendar file" do
      email =
        SeriesConfirmation.render(:organizer, "organizer@example.com", build_series_details(2))

      assert ics(email) == nil
    end
  end
end
