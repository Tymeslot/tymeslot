defmodule Tymeslot.Meetings.AttendeeNotificationsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  describe "event_created/2" do
    test "returns {:ok, :noop} when there are no attendees" do
      event = insert(:provider_calendar_event, attendees: [])
      assert {:ok, :noop} = AttendeeNotifications.event_created(event, [])
    end

    test "enqueues a calendar invitation email per attendee" do
      event =
        insert(:provider_calendar_event,
          summary: "Kickoff",
          attendees: [%{"email" => "a@x.com"}, %{"email" => "b@x.com"}]
        )

      attendees = [%{email: "a@x.com"}, %{email: "b@x.com"}]

      assert {:ok, :sent} = AttendeeNotifications.event_created(event, attendees)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "a@x.com"}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "b@x.com"}
      )
    end

    test "enqueues a :request invitation for a MeetingSchema attendee" do
      meeting = insert(:meeting, attendee_email: "guest@example.com")
      attendees = [%{email: "guest@example.com"}]

      assert {:ok, :sent} = AttendeeNotifications.event_created(meeting, attendees)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "guest@example.com",
          "method" => "request"
        }
      )
    end
  end

  describe "event_updated/3" do
    test "returns {:ok, :no_changes} when nothing notifiable changed" do
      starts_at = ~U[2026-02-01 10:00:00.000000Z]
      ends_at = ~U[2026-02-01 11:00:00.000000Z]

      event =
        insert(:provider_calendar_event,
          summary: "same",
          start_at: starts_at,
          end_at: ends_at,
          location: "HQ",
          description: "",
          attendees: [%{"email" => "a@x.com"}]
        )

      assert {:ok, :no_changes} =
               AttendeeNotifications.event_updated(event, event, [%{email: "a@x.com"}])
    end

    test "returns {:ok, :no_changes} when there are no attendees regardless of diff" do
      event = insert(:provider_calendar_event, summary: "old")
      changed = %{event | summary: "new"}

      assert {:ok, :no_changes} = AttendeeNotifications.event_updated(event, changed, [])
    end

    test "returns {:needs_confirmation, summary} when a notifiable field changed" do
      starts_at = ~U[2026-02-01 10:00:00.000000Z]
      ends_at = ~U[2026-02-01 11:00:00.000000Z]

      event =
        insert(:provider_calendar_event,
          summary: "original",
          start_at: starts_at,
          end_at: ends_at,
          attendees: [%{"email" => "a@x.com"}]
        )

      new_event = %{
        id: event.id,
        uid: event.uid,
        summary: "renamed",
        start_at: starts_at,
        end_at: ends_at,
        location: nil,
        description: nil,
        ical_sequence: event.ical_sequence
      }

      assert {:needs_confirmation, %ChangeSummary{changed_fields: [:title]}} =
               AttendeeNotifications.event_updated(event, new_event, [%{email: "a@x.com"}])
    end
  end

  describe "event_updated_confirm/3" do
    test "delegates to Dispatcher.schedule_update/2" do
      event = insert(:provider_calendar_event)
      summary = %ChangeSummary{changed_fields: [:title], next_sequence: 1}

      assert {:ok, :sent} =
               AttendeeNotifications.event_updated_confirm(event, summary, [
                 %{email: "a@x.com"}
               ])

      assert_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "update"}
      )
    end
  end

  describe "attendees_added/2" do
    test "returns {:ok, :noop} for an empty list" do
      event = insert(:provider_calendar_event)
      assert {:ok, :noop} = AttendeeNotifications.attendees_added(event, [])
    end

    test "sends one invitation per newly-added attendee" do
      event = insert(:provider_calendar_event)

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(event, [%{email: "new@x.com"}])

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "new@x.com"}
      )
    end
  end

  describe "attendees_removed/2" do
    test "returns {:ok, :noop} for an empty list" do
      event = insert(:provider_calendar_event)
      assert {:ok, :noop} = AttendeeNotifications.attendees_removed(event, [])
    end

    test "sends a cancel message per removed attendee" do
      event = insert(:provider_calendar_event, ical_sequence: 2)

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_removed(event, [%{email: "gone@x.com"}])

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "gone@x.com",
          "method" => "cancel"
        }
      )
    end
  end

  describe "event_deleted/2" do
    test "returns {:ok, :no_attendees} when there is nobody to notify" do
      event = insert(:provider_calendar_event)
      assert {:ok, :no_attendees} = AttendeeNotifications.event_deleted(event, [])
    end

    test "returns {:needs_confirmation, N} with the attendee count" do
      event = insert(:provider_calendar_event)
      attendees = [%{email: "a@x.com"}, %{email: "b@x.com"}, %{email: "c@x.com"}]

      assert {:needs_confirmation, 3} = AttendeeNotifications.event_deleted(event, attendees)
    end
  end

  describe "event_deleted_confirm/2" do
    test "delegates to Dispatcher.schedule_delete/2" do
      event = insert(:provider_calendar_event)

      assert {:ok, :sent} =
               AttendeeNotifications.event_deleted_confirm(event, [%{email: "a@x.com"}])

      assert_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "delete"}
      )
    end
  end

  describe "pending?/1 and cancel_pending/1" do
    test "pending?/1 is false before scheduling, true after" do
      event = insert(:provider_calendar_event)
      refute AttendeeNotifications.pending?(event.id)

      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert AttendeeNotifications.pending?(event.id)
    end

    test "cancel_pending/1 removes scheduled jobs for the event" do
      event = insert(:provider_calendar_event)
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      {:ok, :scheduled} = Dispatcher.schedule_delete(event.id, :provider_calendar_event)

      :ok = AttendeeNotifications.cancel_pending(event)

      refute AttendeeNotifications.pending?(event.id)
    end
  end
end
