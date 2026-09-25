defmodule Tymeslot.Workers.EmailWorkerHandlers.CalendarEventEmailsTest do
  @moduledoc """
  The calendar invitation and event update handlers for the two kinds of
  event the timed, previously-notified cases in `IntegrationEmailsTest` do
  not reach: all-day events, and events notified for the first time.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :notifications

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "handle_calendar_invitation/1" do
    test "reads an all-day invitation's dates and gives it no clock time" do
      user = insert(:user)

      expect(EmailServiceMock, :send_calendar_invitation, fn "bob@example.com", details ->
        assert %{
                 all_day: true,
                 date: ~D[2026-10-12],
                 start_date: ~D[2026-10-12],
                 end_date: ~D[2026-10-15],
                 last_date: ~D[2026-10-14],
                 start_time: nil,
                 duration: nil
               } = details

        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "Offsite",
                 "event_uid" => "evt-all-day",
                 "event_start_at" => nil,
                 "event_end_at" => nil,
                 "event_all_day" => true,
                 "event_start_date" => "2026-10-12",
                 "event_end_date" => "2026-10-15"
               })
    end

    test "discards, rather than raising, an all-day invitation enqueued without its dates" do
      user = insert(:user)

      assert {:discard, "Invalid datetime:" <> _rest} =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "Offsite",
                 "event_uid" => "evt-legacy-all-day",
                 "event_start_at" => nil,
                 "event_end_at" => nil
               })
    end
  end

  describe "handle_event_update_notification/1" do
    setup do
      user = insert(:user, name: "Organiser", email: "org@example.com")
      integration = insert(:calendar_integration, user: user)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Updated Title",
          location: "New Room",
          description: "Updated description",
          start_at: ~U[2026-04-10 14:00:00.000000Z],
          end_at: ~U[2026-04-10 15:00:00.000000Z]
        )

      %{user: user, integration: integration, event: event}
    end

    test "reads an all-day cached event's dates and announces a move between days", %{
      user: user,
      integration: integration
    } do
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Offsite",
          all_day: true,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-15],
          start_at: nil,
          end_at: nil
        )

      expect(EmailServiceMock, :send_event_update_notification, fn _email, details ->
        assert %{all_day: true, last_date: ~D[2026-10-14], duration: nil} = details

        assert details.changes == [
                 {:time, Date.range(~D[2026-10-05], ~D[2026-10-07]),
                  Date.range(~D[2026-10-12], ~D[2026-10-14])}
               ]

        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["x@example.com"],
                 "before_title" => "Offsite",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "before_start_date" => "2026-10-05",
                 "before_end_date" => "2026-10-08",
                 "method" => "request"
               })
    end

    test "discards a cached row that carries no timing at all", %{
      user: user,
      integration: integration
    } do
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          all_day: true,
          start_date: nil,
          end_date: nil,
          start_at: nil,
          end_at: nil
        )

      stub(EmailServiceMock, :send_event_update_notification, fn _email, _details ->
        flunk("an event with no timing cannot be described")
      end)

      assert {:discard, "Cached event has no timing"} =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["x@example.com"],
                 "before_title" => "Old",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "method" => "request"
               })
    end

    test "a first notification lists the current fields with no before values", %{
      user: user,
      integration: integration,
      event: event
    } do
      expect(EmailServiceMock, :send_event_update_notification, fn _email, details ->
        assert details.first_notification

        assert details.changes == [
                 {:time, nil, event.start_at},
                 {:title, nil, "Updated Title"},
                 {:location, nil, "New Room"},
                 {:description, nil, "Updated description"}
               ]

        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["x@example.com"],
                 "before_title" => nil,
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "first_notification" => true,
                 "method" => "request"
               })
    end
  end
end
