defmodule Tymeslot.Emails.Templates.BookingApprovalEmailsTest do
  @moduledoc """
  The two emails a held booking produces.

  Rendering is itself the load-bearing assertion: `MjmlEmail.compile_mjml/1`
  raises on malformed markup, so a template that builds at all has produced
  valid MJML. The rest pins the wording that has to be right — that the
  invitee is not told the meeting is confirmed, and that no calendar file
  goes out promising a time nobody has agreed to.
  """

  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :bookings

  alias Ecto.UUID
  alias Tymeslot.Emails.Templates.BookingApprovalRequest
  alias Tymeslot.Emails.Templates.BookingRequestOutcome
  alias Tymeslot.Emails.Templates.BookingRequestReceived
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @urls %{
    review_url: "https://example.com/meeting-request/tok",
    approve_url: "https://example.com/meeting-request/tok?intent=approve",
    decline_url: "https://example.com/meeting-request/tok?intent=decline"
  }

  defp meeting(attrs \\ %{}) do
    base = %Meeting{
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
      attendee_message: "Hoping to talk about Q4.",
      attendee_timezone: "Europe/Ljubljana",
      attendee_locale: "en",
      cancel_url: "https://example.com/sam/meeting/abc-123/cancel",
      approval_deadline_at: ~U[2026-08-30 09:00:00Z],
      status: "awaiting_approval"
    }

    struct!(base, attrs)
  end

  defp calendar_attachment?(attachment) do
    String.ends_with?(attachment.filename || "", ".ics") or
      String.contains?(attachment.content_type || "", "calendar")
  end

  describe "BookingRequestReceived" do
    test "addresses the invitee and never claims the meeting is confirmed" do
      email = BookingRequestReceived.render(meeting())

      assert email.to == [{"Alex Guest", "alex@example.com"}]
      assert email.subject =~ "Request received"
      refute email.subject =~ "Confirmed"

      assert email.html_body =~ "Request received"
      refute email.html_body =~ "is all set"
    end

    test "carries no calendar attachment" do
      # An .ics would put the meeting on the invitee's calendar as though the
      # host had agreed to it, and they would then ignore the real
      # confirmation when it arrives. The inline brand logo is expected and
      # is not a calendar file.
      calendar_parts =
        meeting()
        |> BookingRequestReceived.render()
        |> Map.fetch!(:attachments)
        |> Enum.filter(&calendar_attachment?/1)

      assert calendar_parts == []
    end

    test "names the deadline the invitee is waiting on" do
      html = BookingRequestReceived.render(meeting()).html_body

      assert html =~ "will reply by"
    end

    test "falls back to a vaguer promise when no deadline was recorded" do
      html = BookingRequestReceived.render(meeting(%{approval_deadline_at: nil})).html_body

      assert html =~ "get back to you shortly"
      refute html =~ "will reply by"
    end

    test "offers withdrawal only when there is a cancel link" do
      assert BookingRequestReceived.render(meeting()).html_body =~ "withdraw your request"

      refute BookingRequestReceived.render(meeting(%{cancel_url: nil})).html_body =~
               "withdraw your request"
    end
  end

  describe "BookingApprovalRequest" do
    test "addresses the host and offers both answers" do
      email = BookingApprovalRequest.render(:request, meeting(), @urls, "en")

      assert email.to == [{"Sam Host", "sam@example.com"}]
      assert email.subject =~ "Booking request"
      assert email.html_body =~ @urls.approve_url
      assert email.html_body =~ @urls.decline_url
    end

    test "shows the host what the invitee said" do
      html = BookingApprovalRequest.render(:request, meeting(), @urls, "en").html_body

      assert html =~ "Hoping to talk about Q4."
      assert html =~ "alex@example.com"
    end

    test "states that following a link decides nothing on its own" do
      # The security model depends on the host understanding the buttons open
      # a page rather than acting, so it has to be said in the email.
      html = BookingApprovalRequest.render(:request, meeting(), @urls, "en").html_body

      assert html =~ "Nothing is decided until you choose there."
    end

    test "warns what happens if the host does not answer" do
      html = BookingApprovalRequest.render(:request, meeting(), @urls, "en").html_body

      assert html =~ "the request lapses"
    end

    test "the nudge variant reframes the same request as a reminder" do
      request = BookingApprovalRequest.render(:request, meeting(), @urls, "en")
      nudge = BookingApprovalRequest.render(:nudge, meeting(), @urls, "en")

      assert nudge.subject =~ "Reminder"
      refute request.subject =~ "Reminder"

      assert nudge.html_body =~ "still waiting"
      assert nudge.html_body =~ @urls.approve_url
    end

    test "renders for a host with no message from the invitee" do
      email =
        BookingApprovalRequest.render(:request, meeting(%{attendee_message: nil}), @urls, "en")

      assert email.html_body =~ @urls.approve_url
    end
  end

  describe "BookingRequestOutcome" do
    test "a decline quotes the host's reason back" do
      email =
        BookingRequestOutcome.render(:declined, meeting(%{decline_reason: "Away that week"}))

      assert email.to == [{"Alex Guest", "alex@example.com"}]
      assert email.subject =~ "Request declined"
      assert email.html_body =~ "Away that week"
      assert email.text_body =~ "Away that week"
    end

    test "a decline with no reason invents none" do
      email = BookingRequestOutcome.render(:declined, meeting(%{decline_reason: nil}))

      # Substring without the apostrophe: the sentence is HTML-escaped as a
      # whole (it also carries the organiser's name), so a plain `'` in the
      # static copy renders as `&#39;` in the markup even though it displays
      # correctly.
      assert email.html_body =~ "able to take this booking"
      refute email.html_body =~ "They added:"
      refute email.text_body =~ "They added:"
    end

    test "an expiry does not tell the invitee the host refused" do
      email = BookingRequestOutcome.render(:expired, meeting())

      assert email.subject =~ "Request expired"
      assert email.html_body =~ "get to your request in time"
      refute email.html_body =~ "wasn't able to take this booking"
    end

    test "the two variants do not share a subject line" do
      declined = BookingRequestOutcome.render(:declined, meeting()).subject
      expired = BookingRequestOutcome.render(:expired, meeting()).subject

      assert declined != expired
    end

    test "an expired request never quotes a stale decline reason" do
      # `decline_reason` is only ever written by a decline, but a meeting
      # reaching expiry after an earlier gate cycle could still carry one, and
      # attributing it to a host who simply did not answer would be a lie.
      email =
        BookingRequestOutcome.render(:expired, meeting(%{decline_reason: "Away that week"}))

      refute email.html_body =~ "Away that week"
    end

    test "carries no calendar attachment either" do
      calendar_parts =
        :declined
        |> BookingRequestOutcome.render(meeting())
        |> Map.fetch!(:attachments)
        |> Enum.filter(&calendar_attachment?/1)

      assert calendar_parts == []
    end

    test "an empty decline reason does not print a dangling label" do
      # `Approval.normalise_reason/1` maps `""` to `nil` upstream, but the
      # template must not depend on that being the only writer of the field.
      email = BookingRequestOutcome.render(:declined, meeting(%{decline_reason: ""}))

      refute email.html_body =~ "They added:"
      refute email.text_body =~ "They added:"
    end

    test "preserves newlines a host typed into a decline reason" do
      email =
        BookingRequestOutcome.render(:declined, meeting(%{decline_reason: "Line one\nLine two"}))

      # mrml re-serialises the self-closing tag as `<br />`.
      assert email.html_body =~ "Line one<br />Line two"
      assert email.text_body =~ "Line one\nLine two"
    end
  end

  describe "held-request location classification" do
    test "a held video request shows Video Call rather than TBD" do
      # `location` and `meeting_url` are both nil on a held request — the
      # video room isn't created until the host approves — so the honest
      # signal that this is a video meeting is `video_integration_id`, set at
      # booking time.
      html =
        meeting(%{location: nil, meeting_url: nil, video_integration_id: 42})
        |> BookingRequestReceived.render()
        |> Map.fetch!(:html_body)

      assert html =~ "Video Call"
      refute html =~ "TBD"
    end
  end

  describe "escaping of user-controlled text spliced into HTML" do
    @malicious "<script>alert(1)</script> & \"quoted\" 'single'"
    @escaped "&lt;script&gt;alert(1)&lt;/script&gt;"

    test "BookingApprovalRequest escapes the attendee name" do
      html =
        BookingApprovalRequest.render(
          :request,
          meeting(%{attendee_name: @malicious}),
          @urls,
          "en"
        ).html_body

      refute html =~ "<script>alert(1)</script>"
      assert html =~ @escaped
    end

    test "BookingRequestReceived escapes the organizer name" do
      html = BookingRequestReceived.render(meeting(%{organizer_name: @malicious})).html_body

      refute html =~ "<script>alert(1)</script>"
      assert html =~ @escaped
    end

    test "BookingRequestOutcome escapes the organizer name" do
      email =
        BookingRequestOutcome.render(:declined, meeting(%{organizer_name: @malicious}))

      refute email.html_body =~ "<script>alert(1)</script>"
      assert email.html_body =~ @escaped
    end

    test "BookingRequestOutcome escapes a host-typed decline reason quoted back to the invitee" do
      email =
        BookingRequestOutcome.render(:declined, meeting(%{decline_reason: @malicious}))

      refute email.html_body =~ "<script>alert(1)</script>"
      assert email.html_body =~ @escaped
    end

    test "BookingRequestReceived validates the withdraw link's href and keeps markup out of the msgid" do
      html =
        BookingRequestReceived.render(meeting(%{cancel_url: "javascript:alert(1)"})).html_body

      assert html =~ "withdraw your request"
      refute html =~ "javascript:alert(1)"
      assert html =~ ~s(href="#")
    end
  end
end
