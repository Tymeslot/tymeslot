defmodule Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmailsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "handle_calendar_invitation/1" do
    test "sends an invitation with parsed datetimes and organiser identity" do
      user = insert(:user, name: "Alice Organiser", email: "alice@example.com")

      expect(EmailServiceMock, :send_calendar_invitation, fn "bob@example.com", details ->
        assert details.event_title == "Team Sync"
        assert details.event_uid == "evt-uid-1"
        assert details.start_time == ~U[2026-04-10 10:00:00Z]
        assert details.end_time == ~U[2026-04-10 11:00:00Z]
        assert details.duration == 60
        assert details.location == "Office"
        assert details.organizer_name == "Alice Organiser"
        assert details.organizer_email == "alice@example.com"
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "Team Sync",
                 "event_uid" => "evt-uid-1",
                 "event_start_at" => "2026-04-10T10:00:00Z",
                 "event_end_at" => "2026-04-10T11:00:00Z",
                 "event_location" => "Office",
                 "event_description" => "Discuss Q2 roadmap"
               })
    end

    test "falls back to user.email as organiser_name when name is blank" do
      user = insert(:user, name: nil, email: "noname@example.com")

      expect(EmailServiceMock, :send_calendar_invitation, fn _email, details ->
        assert details.organizer_name == "noname@example.com"
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "guest@example.com",
                 "event_title" => "Quick chat",
                 "event_uid" => "evt-uid-2",
                 "event_start_at" => "2026-04-10T10:00:00Z",
                 "event_end_at" => "2026-04-10T10:15:00Z",
                 "event_location" => nil,
                 "event_description" => nil
               })
    end

    test "discards when the user does not exist" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => 999_999,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "X",
                 "event_uid" => "evt-x",
                 "event_start_at" => "2026-04-10T10:00:00Z",
                 "event_end_at" => "2026-04-10T11:00:00Z",
                 "event_location" => nil,
                 "event_description" => nil
               })
    end

    test "discards on malformed datetime strings" do
      user = insert(:user)

      assert {:discard, "Invalid datetime:" <> _rest} =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "X",
                 "event_uid" => "evt-y",
                 "event_start_at" => "not-a-date",
                 "event_end_at" => "2026-04-10T11:00:00Z",
                 "event_location" => nil,
                 "event_description" => nil
               })
    end

    test "returns retriable error when delivery fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_calendar_invitation, fn _email, _details ->
        {:error, :smtp_unavailable}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_calendar_invitation", %{
                 "user_id" => user.id,
                 "attendee_email" => "bob@example.com",
                 "event_title" => "X",
                 "event_uid" => "evt-z",
                 "event_start_at" => "2026-04-10T10:00:00Z",
                 "event_end_at" => "2026-04-10T11:00:00Z",
                 "event_location" => nil,
                 "event_description" => nil
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
          uid: "evt-update-1",
          summary: "Updated Title",
          location: "New Room",
          description: "Updated description",
          start_at: ~U[2026-04-10 14:00:00.000000Z],
          end_at: ~U[2026-04-10 15:00:00.000000Z]
        )

      %{user: user, integration: integration, event: event}
    end

    test "sends one notification per attendee when fields changed", %{
      user: user,
      integration: integration,
      event: event
    } do
      test_pid = self()

      stub(EmailServiceMock, :send_event_update_notification, fn email, details ->
        send(test_pid, {:notification, email, details})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["a@example.com", "b@example.com"],
                 "before_title" => "Old Title",
                 "before_location" => "Old Room",
                 "before_description" => "Old description",
                 "before_start_at" => "2026-04-10T14:00:00Z",
                 "before_end_at" => "2026-04-10T15:00:00Z",
                 "method" => "request"
               })

      assert_received {:notification, "a@example.com", details}
      assert_received {:notification, "b@example.com", _details}

      assert details.event_title == "Updated Title"
      assert details.organizer_email == "org@example.com"
      assert details.method == :request

      titles = Enum.map(details.changes, &elem(&1, 0))
      assert :title in titles
      assert :location in titles
      assert :description in titles
    end

    test "is a no-op when nothing relevant changed", %{
      user: user,
      integration: integration,
      event: event
    } do
      stub(EmailServiceMock, :send_event_update_notification, fn _email, _details ->
        flunk("should not deliver when no changes are detected")
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["x@example.com"],
                 "before_title" => event.summary,
                 "before_location" => event.location,
                 "before_description" => event.description,
                 "before_start_at" => DateTime.to_iso8601(event.start_at),
                 "before_end_at" => DateTime.to_iso8601(event.end_at),
                 "method" => "request"
               })
    end

    test "parses method=cancel into a :cancel atom", %{
      user: user,
      integration: integration,
      event: event
    } do
      test_pid = self()

      stub(EmailServiceMock, :send_event_update_notification, fn _email, details ->
        send(test_pid, {:method, details.method})
        {:ok, "sent"}
      end)

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
        "method" => "cancel"
      })

      assert_received {:method, :cancel}
    end

    test "discards when the user is not found", %{integration: integration, event: event} do
      assert {:discard, "Event or user not found"} =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => 999_999,
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

    test "discards when the cached event is missing", %{user: user, integration: integration} do
      assert {:discard, "Event or user not found"} =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => "evt-does-not-exist",
                 "attendee_emails" => ["x@example.com"],
                 "before_title" => "Old",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "method" => "request"
               })
    end

    test "discards with a partial-failure reason when some deliveries fail", %{
      user: user,
      integration: integration,
      event: event
    } do
      stub(EmailServiceMock, :send_event_update_notification, fn email, _details ->
        if email == "fail@example.com", do: {:error, :smtp_down}, else: {:ok, "sent"}
      end)

      assert {:discard, "Partial delivery failure:" <> _rest} =
               EmailWorkerHandlers.execute_email_action("send_event_update_notification", %{
                 "user_id" => user.id,
                 "integration_id" => integration.id,
                 "event_uid" => event.uid,
                 "attendee_emails" => ["ok@example.com", "fail@example.com"],
                 "before_title" => "Old Title",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "method" => "request"
               })
    end
  end

  describe "handle_integration_unhealthy_notification/1" do
    test "sends and records notification_sent_at on success" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Pre-existing health state row required for update_fields to update.
      {:ok, _state} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      expect(EmailServiceMock, :send_integration_unhealthy_notification, fn _user,
                                                                            _integration,
                                                                            :calendar ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_unhealthy_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar"
                 }
               )

      {:ok, state} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert %DateTime{} = state.notification_sent_at
    end

    test "discards when the user or integration is missing" do
      assert {:discard, "User or integration not found"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_unhealthy_notification",
                 %{
                   "user_id" => 999_999,
                   "integration_id" => 999_999,
                   "integration_type" => "calendar"
                 }
               )
    end

    test "returns retriable error when delivery fails" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_integration_unhealthy_notification, fn _user,
                                                                            _integration,
                                                                            :calendar ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_unhealthy_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar"
                 }
               )
    end
  end
end
