defmodule Tymeslot.Emails.Templates.EventUpdateNotificationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.EventUpdateNotification

  describe "render/2" do
    test "returns a valid Swoosh email" do
      details = build_event_update_details()
      email = EventUpdateNotification.render("attendee@example.com", details)

      assert %Swoosh.Email{} = email
      assert [{_name, "attendee@example.com"}] = email.to
      assert email.subject =~ "Updated:"
      assert email.subject =~ details.event_title
    end

    test "subject contains event title and formatted date" do
      details =
        build_event_update_details(%{event_title: "Planning Session", date: ~D[2026-04-15]})

      email = EventUpdateNotification.render("a@example.com", details)

      assert email.subject =~ "Planning Session"
      assert email.subject =~ "Apr 15"
    end

    test "HTML body contains change summary" do
      details = build_event_update_details(%{changes: [{:location, "Room A", "Room B"}]})
      email = EventUpdateNotification.render("a@example.com", details)

      assert email.html_body =~ "Room A"
      assert email.html_body =~ "Room B"
    end

    test "text body contains change summary" do
      details = build_event_update_details(%{changes: [{:location, "Old Office", "New Office"}]})
      email = EventUpdateNotification.render("a@example.com", details)

      assert email.text_body =~ "Old Office"
      assert email.text_body =~ "New Office"
    end

    test "includes ICS attachment with SEQUENCE" do
      details = build_event_update_details()
      email = EventUpdateNotification.render("a@example.com", details)

      ics_attachments =
        Enum.filter(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert [attachment] = ics_attachments
      assert attachment.filename =~ ".ics"
      assert attachment.content_type =~ "text/calendar"
      assert attachment.data =~ "SEQUENCE:1"
    end

    test "handles time change" do
      details =
        build_event_update_details(%{
          changes: [{:time, ~U[2026-04-10 10:00:00Z], ~U[2026-04-10 14:00:00Z]}]
        })

      email = EventUpdateNotification.render("a@example.com", details)
      assert email.html_body =~ "10:00"
      assert email.html_body =~ "14:00"
    end

    test "description change shows updated without diff" do
      details = build_event_update_details(%{changes: [{:description, "Old text", "New text"}]})
      email = EventUpdateNotification.render("a@example.com", details)

      assert email.html_body =~ "(updated)"
      refute email.html_body =~ "Old text"
    end

    test "multiple simultaneous changes all appear" do
      details =
        build_event_update_details(%{
          changes: [
            {:title, "Old Title", "New Title"},
            {:location, "Room A", "Room B"},
            {:description, "Old", "New"}
          ]
        })

      email = EventUpdateNotification.render("a@example.com", details)
      assert email.html_body =~ "Old Title"
      assert email.html_body =~ "New Title"
      assert email.html_body =~ "Room A"
      assert email.html_body =~ "(updated)"
    end

    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr", "it"] do
        details = build_event_update_details(%{attendee_locale: locale})
        email = EventUpdateNotification.render("a@example.com", details)

        assert %Swoosh.Email{} = email, "Failed for locale: #{locale}"
        assert email.html_body != nil, "No HTML body for locale: #{locale}"
        assert email.text_body != nil, "No text body for locale: #{locale}"
      end
    end

    test "omits the 'What changed' block when no recognised changes are present" do
      details = build_event_update_details(%{changes: []})
      email = EventUpdateNotification.render("a@example.com", details)

      refute email.html_body =~ "What changed"
    end

    test "omits the 'What changed' block when every change is filtered out" do
      details = build_event_update_details(%{changes: [{:unknown_field, "a", "b"}]})
      email = EventUpdateNotification.render("a@example.com", details)

      refute email.html_body =~ "What changed"
    end

    test "sanitises HTML in organiser name" do
      details = build_event_update_details(%{organizer_name: "<script>alert('xss')</script>Evil"})
      email = EventUpdateNotification.render("a@example.com", details)

      refute email.html_body =~ "<script>"
    end
  end
end
