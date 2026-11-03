defmodule Tymeslot.Notifications.Email.CalendarEventDetailsTest do
  @moduledoc """
  Dashboard invitations and event updates go to people the organiser added to
  an event, whose language and timezone are unknown, so they are written as
  the organiser sees the event: the organiser's timezone, the date there, and
  the organiser's language.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :calendar

  alias Tymeslot.Emails.Templates.CalendarInvitation
  alias Tymeslot.Emails.Templates.EventUpdateNotification
  alias Tymeslot.Notifications.Email.CalendarEventDetails

  setup do
    user = insert(:user, locale: "de")
    insert(:profile, user: user, timezone: "Europe/Berlin")
    %{user: user}
  end

  # 23:30 UTC on 2 November is 00:30 on 3 November in Berlin.
  @start_at "2026-11-02T23:30:00Z"
  @end_at "2026-11-03T00:30:00Z"

  describe "invitation_details/2" do
    test "states the event in the organiser's timezone, on the day it falls there", %{user: user} do
      {:ok, details} = CalendarEventDetails.invitation_details(user, invitation_args())

      assert details.date == ~D[2026-11-03]
      assert {details.start_time.hour, details.start_time.minute} == {0, 30}
      assert details.timezone == "Europe/Berlin"
      assert details.attendee_locale == "de"
    end

    test "the invitation reads in the organiser's language and clock", %{user: user} do
      {:ok, details} = CalendarEventDetails.invitation_details(user, invitation_args())

      email = CalendarInvitation.render("guest@example.com", details)

      assert email.html_body =~ "00:30"
      assert email.html_body =~ "Europe/Berlin"
      assert email.text_body =~ "00:30"
      refute email.text_body =~ "23:30"
    end
  end

  describe "update_details/4" do
    test "states the event and its time change in the organiser's timezone", %{user: user} do
      event = %{
        uid: "uid-1",
        summary: "Planning",
        location: nil,
        description: nil,
        all_day: false,
        start_at: ~U[2026-11-02 23:30:00Z],
        end_at: ~U[2026-11-03 00:30:00Z]
      }

      args = %{
        "before_start_at" => "2026-11-02T22:30:00Z",
        "before_end_at" => "2026-11-02T23:30:00Z"
      }

      changes = CalendarEventDetails.changes(event, args)
      {:ok, details} = CalendarEventDetails.update_details(user, event, changes, args)

      assert details.date == ~D[2026-11-03]
      assert details.attendee_locale == "de"

      email = EventUpdateNotification.render("guest@example.com", details)

      assert email.text_body =~ "23:30 CET"
      assert email.text_body =~ "00:30 CET"
      refute email.text_body =~ "UTC"
    end
  end

  describe "changes/2" do
    @event %{
      uid: "uid-1",
      summary: "Planning",
      location: nil,
      description: "Agenda\n\nJoin video call: https://zoom.example/j/new",
      video_link: "https://zoom.example/j/new",
      all_day: false,
      start_at: ~U[2026-11-02 23:30:00Z],
      end_at: ~U[2026-11-03 00:30:00Z]
    }

    test "a new room is a video change, not a description change" do
      args = %{
        "before_title" => "Planning",
        "before_description" => "Agenda\n\nJoin video call: https://zoom.example/j/old",
        "before_video_link" => "https://zoom.example/j/old"
      }

      assert CalendarEventDetails.changes(@event, args) == [
               {:video_link, "https://zoom.example/j/old", "https://zoom.example/j/new"}
             ]
    end

    test "a job that never recorded the previous link announces no video change" do
      args = %{"before_title" => "Planning", "before_description" => "Agenda"}

      assert CalendarEventDetails.changes(@event, args) == []
    end

    test "a first notification states the link and the description without its join line" do
      changes = CalendarEventDetails.changes(@event, %{"first_notification" => true})

      assert {:description, nil, "Agenda"} in changes
      assert {:video_link, nil, "https://zoom.example/j/new"} in changes
    end

    test "the event a series update carries keeps its link" do
      {:ok, event} =
        CalendarEventDetails.snapshot_event(%{
          "uid" => "uid-1",
          "summary" => "Planning",
          "video_link" => "https://zoom.example/j/new",
          "start_at" => "2026-11-02T23:30:00Z",
          "end_at" => "2026-11-03T00:30:00Z"
        })

      changes = CalendarEventDetails.changes(event, %{"before_video_link" => nil})
      assert {:video_link, nil, "https://zoom.example/j/new"} in changes
    end
  end

  defp invitation_args do
    %{
      "event_title" => "Planning",
      "event_uid" => "uid-1",
      "event_start_at" => @start_at,
      "event_end_at" => @end_at,
      "event_location" => nil,
      "event_description" => nil
    }
  end
end
