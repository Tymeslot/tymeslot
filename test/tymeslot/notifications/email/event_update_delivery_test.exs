defmodule Tymeslot.Notifications.Email.EventUpdateDeliveryTest do
  @moduledoc """
  A dashboard calendar update email that fails for some guests: the job
  retries them without re-mailing the guests already reached, and each guest
  still unreached is recorded on the event for the organiser.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :workers

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.UndeliveredUpdates
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Notifications.Email.IntegrationEmails
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user, name: "Organiser", email: "org@example.com")
    integration = insert(:calendar_integration, user: user)

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "evt-update-1",
        summary: "Updated Title",
        start_at: ~U[2026-04-10 14:00:00.000000Z],
        end_at: ~U[2026-04-10 15:00:00.000000Z]
      )

    %{user: user, integration: integration, event: event}
  end

  # A guest the email fails for is retried, and recorded on the event for
  # the organiser meanwhile; the retry that reaches them clears the record
  # and re-mails nobody already reached.
  test "retries a failed guest only, recording them until the retry delivers", %{
    user: user,
    integration: integration,
    event: event
  } do
    test_pid = self()
    job_id = System.unique_integer([:positive])
    args = update_args(user, integration, event, ["ok@example.com", "fail@example.com"])

    stub(EmailServiceMock, :send_event_update_notification, fn email, _details ->
      send(test_pid, {:sent, email})
      if email == "fail@example.com", do: {:error, :smtp_down}, else: {:ok, "sent"}
    end)

    assert {:error, reason} = IntegrationEmails.handle_event_update_notification(args, job_id)
    refute match?({:recipient_rejected, _rejection}, reason)
    refute reason == :circuit_open
    assert_received {:sent, "ok@example.com"}
    assert_received {:sent, "fail@example.com"}

    assert UndeliveredUpdates.list_for_event(user.id, integration.id, event.uid) ==
             ["fail@example.com"]

    stub(EmailServiceMock, :send_event_update_notification, fn email, _details ->
      send(test_pid, {:sent, email})
      {:ok, "sent"}
    end)

    assert :ok = IntegrationEmails.handle_event_update_notification(args, job_id)
    assert_received {:sent, "fail@example.com"}
    refute_received {:sent, "ok@example.com"}
    assert UndeliveredUpdates.list_for_event(user.id, integration.id, event.uid) == []
  end

  test "discards a permanently rejected guest and leaves them recorded", %{
    user: user,
    integration: integration,
    event: event
  } do
    stub(EmailServiceMock, :send_event_update_notification, fn
      "gone@example.com", _details -> {:error, {:recipient_rejected, {550, "no such user"}}}
      _email, _details -> {:ok, "sent"}
    end)

    args =
      user
      |> update_args(integration, event, ["ok@example.com", "gone@example.com"])
      |> Map.put("action", "send_event_update_notification")

    assert {:discard, _reason} = perform_job(EmailWorker, args)

    assert UndeliveredUpdates.list_for_event(user.id, integration.id, event.uid) ==
             ["gone@example.com"]
  end

  test "records a failed guest again without duplicating them", %{
    user: user,
    integration: integration,
    event: event
  } do
    stub(EmailServiceMock, :send_event_update_notification, fn _email, _details ->
      {:error, :smtp_down}
    end)

    args = update_args(user, integration, event, ["fail@example.com"])
    job_id = System.unique_integer([:positive])

    assert {:error, _reason} = IntegrationEmails.handle_event_update_notification(args, job_id)
    assert {:error, _reason} = IntegrationEmails.handle_event_update_notification(args, job_id)

    assert UndeliveredUpdates.list_for_event(user.id, integration.id, event.uid) ==
             ["fail@example.com"]
  end

  defp update_args(user, integration, event, attendee_emails) do
    %{
      "user_id" => user.id,
      "integration_id" => integration.id,
      "event_uid" => event.uid,
      "attendee_emails" => attendee_emails,
      "before_title" => "Old Title",
      "before_location" => nil,
      "before_description" => nil,
      "before_start_at" => nil,
      "before_end_at" => nil,
      "method" => "request"
    }
  end
end
