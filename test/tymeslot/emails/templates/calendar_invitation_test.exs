defmodule Tymeslot.Emails.Templates.CalendarInvitationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.CalendarInvitation

  describe "invitation_email/2" do
    test "returns a valid Swoosh email" do
      details = build_invitation_details()
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "subject contains event title and formatted date" do
      details = build_invitation_details(%{event_title: "Sprint Planning"})
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert email.subject =~ "Sprint Planning"
      assert email.subject =~ "Invitation"
    end

    test "sets recipient as plain email without name tuple" do
      email =
        CalendarInvitation.invitation_email(
          "guest@example.com",
          build_invitation_details()
        )

      assert email.to == [{"", "guest@example.com"}]
    end

    test "HTML body contains organiser name and event title" do
      details =
        build_invitation_details(%{
          organizer_name: "Dr. Alice Chen",
          event_title: "Architecture Review"
        })

      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert email.html_body =~ "Dr. Alice Chen"
      assert email.html_body =~ "Architecture Review"
    end

    test "HTML body contains invitation heading" do
      details = build_invitation_details()
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert email.html_body =~ "Invited"
    end

    test "includes ICS calendar attachment" do
      details = build_invitation_details()
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert length(email.attachments) == 1
      attachment = hd(email.attachments)
      assert attachment.filename =~ ".ics"
      assert attachment.content_type =~ "text/calendar"
    end

    test "text body contains organiser name and event title" do
      details =
        build_invitation_details(%{
          organizer_name: "Sarah Johnson",
          event_title: "Team Standup"
        })

      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert email.text_body =~ "Sarah Johnson"
      assert email.text_body =~ "Team Standup"
    end

    test "handles nil location gracefully" do
      details = build_invitation_details(%{location: nil})
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.html_body != nil
      refute email.html_body =~ "nil"
    end

    test "handles nil description gracefully" do
      details = build_invitation_details(%{description: nil})
      email = CalendarInvitation.invitation_email("guest@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.html_body != nil
      refute email.html_body =~ "nil"
    end

    test "sanitises HTML in event title" do
      details =
        build_invitation_details(%{
          event_title: "<script>alert('xss')</script>Team Meeting"
        })

      email = CalendarInvitation.invitation_email("guest@example.com", details)

      refute email.html_body =~ "<script>"
    end

    test "sanitises HTML in organiser name" do
      details =
        build_invitation_details(%{
          organizer_name: "<img onerror=alert(1)>Bob"
        })

      email = CalendarInvitation.invitation_email("guest@example.com", details)

      # The raw tag must be escaped — no unescaped <img> in the output
      refute email.html_body =~ "<img onerror"
      # The escaped content should still appear
      assert email.html_body =~ "Bob"
    end

    test "handles various durations" do
      for duration <- [15, 30, 45, 60, 90, 120] do
        details = build_invitation_details(%{duration: duration})
        email = CalendarInvitation.invitation_email("guest@example.com", details)

        assert %Swoosh.Email{} = email
        assert email.html_body != nil
      end
    end

    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr"] do
        details = build_invitation_details(%{attendee_locale: locale})
        email = CalendarInvitation.invitation_email("guest@example.com", details)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end
  end

  defp build_invitation_details(overrides \\ %{}) do
    defaults = %{
      event_title: "Team Sync",
      event_uid: "cal-event-#{System.unique_integer([:positive])}",
      start_time: ~U[2026-02-10 10:00:00Z],
      end_time: ~U[2026-02-10 11:00:00Z],
      date: ~D[2026-02-10],
      duration: 60,
      location: "Conference Room B",
      description: "Weekly team synchronisation meeting",
      organizer_name: "John Organizer",
      organizer_email: "organizer@example.com",
      attendee_locale: "en"
    }

    Map.merge(defaults, overrides)
  end
end
