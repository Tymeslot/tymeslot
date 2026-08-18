defmodule Tymeslot.Emails.Templates.CalendarInvitationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.CalendarInvitation

  describe "render/2" do
    test "returns a valid Swoosh email" do
      details = build_invitation_details()
      email = CalendarInvitation.render("guest@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.subject =~ "Team Sync"
      assert email.to == [{"", "guest@example.com"}]
      assert email.html_body =~ "Team Sync"
      assert email.text_body =~ "Team Sync"
    end

    test "subject contains event title and formatted date" do
      details = build_invitation_details(%{event_title: "Sprint Planning"})
      email = CalendarInvitation.render("guest@example.com", details)

      assert email.subject =~ "Sprint Planning"
      assert email.subject =~ "Invitation"
    end

    test "sets recipient as plain email without name tuple" do
      email =
        CalendarInvitation.render(
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

      email = CalendarInvitation.render("guest@example.com", details)

      assert email.html_body =~ "Dr. Alice Chen"
      assert email.html_body =~ "Architecture Review"
    end

    test "HTML body contains invitation heading" do
      details = build_invitation_details()
      email = CalendarInvitation.render("guest@example.com", details)

      assert email.html_body =~ "Invited"
    end

    test "includes ICS calendar attachment" do
      details = build_invitation_details()
      email = CalendarInvitation.render("guest@example.com", details)

      assert ics_attachment =
               Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics_attachment.filename =~ ".ics"
    end

    test "text body contains organiser name and event title" do
      details =
        build_invitation_details(%{
          organizer_name: "Sarah Johnson",
          event_title: "Team Standup"
        })

      email = CalendarInvitation.render("guest@example.com", details)

      assert email.text_body =~ "Sarah Johnson"
      assert email.text_body =~ "Team Standup"
    end

    test "handles nil location gracefully" do
      details = build_invitation_details(%{location: nil})
      email = CalendarInvitation.render("guest@example.com", details)

      assert email.html_body =~ "Team Sync"
      refute email.html_body =~ "nil"
    end

    test "handles nil description gracefully" do
      details = build_invitation_details(%{description: nil})
      email = CalendarInvitation.render("guest@example.com", details)

      assert email.html_body =~ "Team Sync"
      refute email.html_body =~ "nil"
    end

    test "sanitises HTML in event title" do
      details =
        build_invitation_details(%{
          event_title: "<script>alert('xss')</script>Team Meeting"
        })

      email = CalendarInvitation.render("guest@example.com", details)

      refute email.html_body =~ "<script>"
    end

    test "sanitises HTML in organiser name" do
      details =
        build_invitation_details(%{
          organizer_name: "<img onerror=alert(1)>Bob"
        })

      email = CalendarInvitation.render("guest@example.com", details)

      # The raw tag must be escaped — no unescaped <img> in the output
      refute email.html_body =~ "<img onerror"
      # The escaped content should still appear
      assert email.html_body =~ "Bob"
    end

    test "renders each supported duration in human-readable form" do
      for {duration, rendered} <- [
            {15, "15 minutes"},
            {30, "30 minutes"},
            {45, "45 minutes"},
            {60, "1 hour"},
            {90, "1.5 hours"},
            {120, "2 hours"}
          ] do
        details = build_invitation_details(%{duration: duration})
        email = CalendarInvitation.render("guest@example.com", details)

        assert email.html_body =~ rendered,
               "expected #{duration} minutes to render as #{rendered}"
      end
    end

    test "translates the subject and the invitation heading for every supported locale" do
      for {locale, subject_fragment, heading} <- [
            {"en", "Calendar Invitation", "You're Invited"},
            {"de", "Kalendereinladung", "Sie sind eingeladen"},
            {"uk", "Запрошення до календаря", "Вас запрошено"},
            {"fr", "Invitation :", "Vous êtes invité(e)"},
            {"it", "Invito di calendario", "Hai ricevuto un invito"}
          ] do
        details = build_invitation_details(%{attendee_locale: locale})
        email = CalendarInvitation.render("guest@example.com", details)

        assert email.subject =~ subject_fragment,
               "Expected #{locale} subject to contain #{inspect(subject_fragment)}, got: #{email.subject}"

        assert email.text_body =~ heading,
               "Expected #{locale} text body to contain #{inspect(heading)}"

        # The event title is never translated, so it must survive every locale.
        assert email.subject =~ "Team Sync"

        if locale != "en" do
          refute email.subject =~ "Calendar Invitation",
                 "Expected #{locale} subject to drop the English wording"

          refute email.text_body =~ "You're Invited",
                 "Expected #{locale} text body to drop the English heading"
        end
      end
    end

    test "subject is free of CR/LF when event title contains header-injection payload" do
      details =
        build_invitation_details(%{event_title: "Sprint Planning\r\nBcc: attacker@evil.com"})

      email = CalendarInvitation.render("guest@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
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
