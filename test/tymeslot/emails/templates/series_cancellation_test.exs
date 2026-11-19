defmodule Tymeslot.Emails.Templates.SeriesCancellationTest do
  @moduledoc """
  Render tests for `SeriesCancellation`: several sessions of a series
  cancelled at once, told to the booker and the organiser in one email each.
  """

  use ExUnit.Case, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.SeriesCancellation

  defp details(cancelled_by, attrs \\ %{}),
    do: build_series_details(2, Map.put(attrs, :cancelled_by, cancelled_by))

  defp ics(email), do: Enum.find(email.attachments, &(&1.content_type == "text/calendar"))

  test "the attendee's subject counts the cancelled sessions" do
    email = SeriesCancellation.render(:attendee, "ada@example.com", details(:attendee))
    assert email.subject == "2 sessions cancelled"
  end

  test "the organiser's subject says who cancelled" do
    by_attendee = SeriesCancellation.render(:organizer, "o@example.com", details(:attendee))
    by_organizer = SeriesCancellation.render(:organizer, "o@example.com", details(:organizer))

    assert by_attendee.subject == "Jane Attendee cancelled 2 sessions"
    assert by_organizer.subject == "You cancelled 2 sessions with Jane Attendee"
  end

  test "the attendee's copy is worded for who cancelled" do
    by_host = SeriesCancellation.render(:attendee, "ada@example.com", details(:organizer))
    by_self = SeriesCancellation.render(:attendee, "ada@example.com", details(:attendee))

    assert by_host.text_body =~ "I've had to cancel the sessions below"
    assert by_self.text_body =~ "as you asked"
  end

  test "lists the cancelled sessions without their links" do
    details = details(:attendee)
    email = SeriesCancellation.render(:attendee, "ada@example.com", details)

    for session <- details.sessions do
      assert email.text_body =~ "Session #{session.position} of 2"
      refute email.text_body =~ session.cancel_url
      refute email.text_body =~ session.attendee_video_url
    end
  end

  test "one calendar file cancels every session one revision up" do
    details = details(:attendee, %{session: %{ical_sequence: 1}})
    email = SeriesCancellation.render(:attendee, "ada@example.com", details)
    data = ics(email).data

    assert ics(email).filename == "series-#{details.series.uid}.ics"
    refute data =~ "METHOD:CANCEL"
    assert length(Regex.scan(~r/^BEGIN:VEVENT/m, data)) == 2
    assert length(Regex.scan(~r/^STATUS:CANCELLED/m, data)) == 2
    assert length(Regex.scan(~r/^SEQUENCE:2/m, data)) == 2

    for session <- details.sessions, do: assert(data =~ "UID:#{session.uid}@")
  end

  test "the organiser's copy carries no calendar file" do
    email = SeriesCancellation.render(:organizer, "o@example.com", details(:attendee))
    assert ics(email) == nil
  end
end
