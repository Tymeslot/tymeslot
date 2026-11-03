defmodule Tymeslot.Meetings.AttendeeNotifications.CalendarEventEmailContentTest do
  @moduledoc """
  What the emails sent for a dashboard calendar event tell its guests,
  carried all the way to the delivered email (`Tymeslot.Test.AttendeeEmailDelivery`):
  the video link through a change of room, the time as a range, how a series
  repeats, the description, the sender, and what a removal or a cancellation
  leaves in the guest's calendar.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications
  @moduletag :emails

  import Tymeslot.Factory
  import Tymeslot.Test.AttendeeEmailDelivery

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState

  setup do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user, name: "Olive Organiser")
    integration = insert(:calendar_integration, user: user)

    %{user: user, integration: integration}
  end

  describe "a change of video room" do
    setup %{integration: integration} do
      start_at = ~U[2026-11-03 09:30:00.000000Z]
      end_at = ~U[2026-11-03 09:45:00.000000Z]

      baseline =
        LastNotifiedState.serialise(
          %{
            title: "Standup",
            starts_at: start_at,
            ends_at: end_at,
            location: "",
            description: "Agenda\n\nJoin video call: https://zoom.example/j/old",
            video_link: "https://zoom.example/j/old"
          },
          [%{email: "guest@example.com"}]
        )

      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: start_at,
          end_at: end_at,
          description: "Agenda\n\nJoin video call: https://zoom.example/j/new",
          video_link: "https://zoom.example/j/new",
          last_notified_state: baseline
        )

      %{event: event}
    end

    test "announces the new link, not a description change", %{event: event} do
      email = run_update_to_delivery(event)

      assert email.text_body =~
               "Video call: https://zoom.example/j/old → https://zoom.example/j/new"

      refute email.text_body =~ "Description:"
      assert email.html_body =~ "https://zoom.example/j/new"
      assert email.text_body =~ "Location: Video Call"
    end

    test "keeps the new link in the guest's calendar entry", %{event: event} do
      ics = calendar_attachment(run_update_to_delivery(event)).data

      assert ics =~ "CONFERENCE;VALUE=URI"
      assert ics =~ "https://zoom.example/j/new"
      refute ics =~ "j/old"
      refute ics =~ "Join video call"
    end
  end

  describe "a video room added to an event notified without one" do
    test "shows the previous link as none", %{integration: integration} do
      start_at = ~U[2026-11-03 09:30:00.000000Z]
      end_at = ~U[2026-11-03 09:45:00.000000Z]

      baseline =
        LastNotifiedState.serialise(
          %{
            title: "Standup",
            starts_at: start_at,
            ends_at: end_at,
            location: "",
            description: ""
          },
          [%{email: "guest@example.com"}]
        )

      assert baseline["video_link"] == ""

      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: start_at,
          end_at: end_at,
          video_link: "https://zoom.example/j/new",
          last_notified_state: baseline
        )

      email = run_update_to_delivery(event)

      assert email.text_body =~ "Video call: (none) → https://zoom.example/j/new"
    end
  end

  describe "an update that moves only the end" do
    test "shows the end that moved", %{integration: integration} do
      start_at = ~U[2026-11-03 09:30:00.000000Z]

      baseline =
        LastNotifiedState.serialise(
          %{
            title: "Standup",
            starts_at: start_at,
            ends_at: ~U[2026-11-03 09:45:00.000000Z],
            location: "",
            description: ""
          },
          [%{email: "guest@example.com"}]
        )

      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: start_at,
          end_at: ~U[2026-11-03 10:00:00.000000Z],
          last_notified_state: baseline
        )

      email = run_update_to_delivery(event)

      assert email.text_body =~
               "Time: 03 Nov 2026, 11:30 – 11:45 EET (Europe/Tallinn) → 03 Nov 2026, 11:30 – 12:00 EET"
    end
  end

  describe "an invitation" do
    test "to a series just created says how it repeats, in a single calendar entry", %{
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "Weekly sync",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 10:00:00.000000Z],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"
        )

      assert {:ok, :sent} =
               AttendeeNotifications.event_created(event, [%{email: "new@example.com"}])

      assert [email] = deliver_all("send_calendar_invitation")
      assert email.text_body =~ "Repeats weekly on Tue"
      ics = calendar_attachment(email).data
      assert ics =~ "BEGIN:VEVENT"
      refute ics =~ "RRULE"
    end

    test "to an occurrence carrying its series' rule is for that occurrence alone", %{
      user: user,
      integration: integration
    } do
      # A CalDAV occurrence row: the series' rule, and no `recurring_event_id`.
      event =
        insert_timed_event(integration,
          summary: "Weekly sync",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 10:00:00.000000Z],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"
        )

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(
                 event,
                 [%{email: "new@example.com"}],
                 user.id
               )

      assert [email] = deliver_all("send_calendar_invitation")
      refute email.text_body =~ "Repeats"
      refute calendar_attachment(email).data =~ "RRULE"
    end

    test "cancelling a whole series writes no rule into the cancellation", %{
      user: user,
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "Weekly sync",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 10:00:00.000000Z],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"
        )

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)

      assert [email] = deliver_all("send_calendar_invitation")
      ics = calendar_attachment(email).data
      assert ics =~ "STATUS:CANCELLED"
      refute ics =~ "RRULE"
    end

    test "sent again after a removal supersedes the cancellation", %{
      user: user,
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 09:45:00.000000Z],
          ical_sequence: 3
        )

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(
                 event,
                 [%{email: "back@example.com"}],
                 user.id
               )

      assert [email] = deliver_all("send_calendar_invitation")
      assert calendar_attachment(email).data =~ "SEQUENCE:3"
    end

    test "states the description without its join line, and the title as the event", %{
      user: user,
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 09:45:00.000000Z],
          description: "Bring the numbers\n\nJoin video call: https://zoom.example/j/1",
          video_link: "https://zoom.example/j/1"
        )

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(
                 event,
                 [%{email: "new@example.com"}],
                 user.id
               )

      assert [email] = deliver_all("send_calendar_invitation")
      assert email.text_body =~ "Event: Standup"
      refute email.text_body =~ "Type:"
      assert email.text_body =~ "DESCRIPTION:\nBring the numbers"
      refute email.text_body =~ "Join video call:"
      assert {"Olive Organiser", _instance_address} = email.from
    end

    test "is not sent to the organiser's own address", %{user: user, integration: integration} do
      event = insert_timed_event(integration, start_at: ~U[2026-11-03 09:30:00.000000Z])

      assert {:ok, :noop} =
               AttendeeNotifications.attendees_added(event, [%{email: user.email}], user.id)

      assert enqueued_jobs("send_calendar_invitation") == []
    end
  end

  describe "the cancellation sent to a removed attendee" do
    test "states no join link", %{user: user, integration: integration} do
      event =
        insert_timed_event(integration,
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 09:45:00.000000Z],
          video_link: "https://zoom.example/j/1"
        )

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_removed(
                 event,
                 [%{email: "gone@example.com"}],
                 user.id
               )

      assert [email] = deliver_all("send_calendar_invitation")
      refute calendar_attachment(email).data =~ "zoom.example"
      refute email.text_body =~ "zoom.example"
    end
  end
end
