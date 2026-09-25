defmodule Tymeslot.Workers.EventUpdateNotificationRescueTest do
  @moduledoc """
  One `send_event_update_notification` job carries every recipient of a
  calendar event change, so a job the Oban lifeline re-runs after it sent
  must not mail the whole list a second time.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :notifications

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  test "a rescued job notifies each attendee only once" do
    user = insert(:user, name: "Organiser", email: "org@example.com")
    integration = insert(:calendar_integration, user: user)

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "evt-rescue-1",
        summary: "Updated Title",
        location: "New Room",
        description: "Updated description",
        start_at: ~U[2026-04-10 14:00:00.000000Z],
        end_at: ~U[2026-04-10 15:00:00.000000Z]
      )

    test_pid = self()

    stub(EmailServiceMock, :send_event_update_notification, fn email, _details ->
      send(test_pid, {:notification, email})
      {:ok, "sent"}
    end)

    job =
      persisted_job(EmailWorker, %{
        "action" => "send_event_update_notification",
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

    assert :ok = EmailWorker.perform(job)
    assert :ok = EmailWorker.perform(job)

    assert_received {:notification, "a@example.com"}
    assert_received {:notification, "b@example.com"}
    refute_received {:notification, _duplicate}
  end
end
