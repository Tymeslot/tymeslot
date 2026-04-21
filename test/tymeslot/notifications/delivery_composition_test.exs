defmodule Tymeslot.Notifications.DeliveryCompositionTest do
  @moduledoc """
  End-to-end composition coverage for the attendee-notification pipeline:

      event trigger → recipient resolution → template rendering → email delivery

  Two hot paths are pinned here:

    * the **outer** `Tymeslot.Meetings.AttendeeNotifications.Worker` walks the
      diff of a calendar event against its `last_notified_state`, resolves
      the per-recipient args, and enqueues an `EmailWorker` job inside the
      same transaction that bumps `ical_sequence` — asserted together so a
      regression in either half surfaces here.
    * the **inner** `EmailWorker` handler
      (`EmailWorkerHandlers.IntegrationEmails.handle_event_update_notification/1`)
      loops over `attendee_emails` and, when any recipient's send fails,
      returns `{:discard, "Partial delivery failure: N of M failed"}` —
      a shape nothing else in the suite locks in today.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.AttendeeNotifications.Worker, as: AttendeeWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "outer Worker — trigger → recipient resolution → job dispatch" do
    test "diffs the event, bumps ical_sequence, and enqueues the notification job" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # The event's current state diverges from `last_notified_state` on the
      # title — that's the change the detector picks up. `attendees` stays
      # identical, so the attendee survives as a retained recipient and the
      # `:update` dispatch fans out to them.
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "New Title",
          attendees: [%{"email" => "retained@example.com"}],
          ical_sequence: 4,
          # LastNotifiedState.to_event/1 reads attendees as a list of strings.
          last_notified_state: %{
            "title" => "Old Title",
            "attendees" => ["retained@example.com"]
          }
        )

      assert :ok =
               perform_job(AttendeeWorker, %{
                 "event_id" => event.id,
                 "kind" => "provider_calendar_event",
                 "action" => "update"
               })

      # Recipient resolution landed on the retained attendee.
      assert [job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{
                   "action" => "send_event_update_notification",
                   "event_uid" => event.uid
                 }
               )

      assert job.args["attendee_emails"] == ["retained@example.com"]
      assert job.args["integration_id"] == integration.id
      assert job.args["before_title"] == "Old Title"

      # ical_sequence and last_notified_state are persisted atomically with
      # the dispatch — so a retry after a crash doesn't re-notify.
      {:ok, reloaded} = ProviderCalendarEventQueries.fetch(event.id)
      assert reloaded.ical_sequence == 5
      assert reloaded.last_notified_state["title"] == "New Title"
    end
  end

  describe "inner EmailWorker — partial delivery failure" do
    test "discards with 'Partial delivery failure: X of N' when any recipient send fails" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "New Title"
        )

      # Template rendering + delivery run for real; only the email-service
      # module is mocked (that's the system boundary). The middle attendee
      # fails — the other two succeed.
      expect(EmailServiceMock, :send_event_update_notification, 3, fn email, _details ->
        case email do
          "b@example.com" -> {:error, "smtp-bounce"}
          _other -> {:ok, "sent"}
        end
      end)

      assert {:discard, message} =
               perform_job(EmailWorker, %{
                 "action" => "send_event_update_notification",
                 "user_id" => user.id,
                 "event_uid" => event.uid,
                 "integration_id" => integration.id,
                 "attendee_emails" => [
                   "a@example.com",
                   "b@example.com",
                   "c@example.com"
                 ],
                 "before_title" => "Old Title",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "method" => "request",
                 "sequence" => 2
               })

      assert message == "Partial delivery failure: 1 of 3 failed"
    end

    test "returns :ok when every recipient's send succeeds" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "New Title"
        )

      expect(EmailServiceMock, :send_event_update_notification, 2, fn _email, _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_event_update_notification",
                 "user_id" => user.id,
                 "event_uid" => event.uid,
                 "integration_id" => integration.id,
                 "attendee_emails" => ["a@example.com", "b@example.com"],
                 "before_title" => "Old Title",
                 "before_location" => nil,
                 "before_description" => nil,
                 "before_start_at" => nil,
                 "before_end_at" => nil,
                 "method" => "request",
                 "sequence" => 2
               })
    end
  end
end
