defmodule Tymeslot.Meetings.AttendeeNotifications.DeliveryCompositionTest do
  @moduledoc """
  End-to-end composition coverage for the attendee-notification pipeline:

      event trigger → recipient resolution → template rendering → email delivery

  Two hot paths are pinned here:

    * the **end-to-end chain**: `Tymeslot.Meetings.AttendeeNotifications.Worker`
      diffs a calendar event against its `last_notified_state`, bumps
      `ical_sequence`, and enqueues an `EmailWorker` job — the test then feeds
      that job's own args into `perform_job(EmailWorker, …)`, so a rename or
      reshape between producer (`CalendarScheduler.schedule_event_update_notification/1`)
      and consumer (`EmailWorkerHandlers.IntegrationEmails.handle_event_update_notification/1`)
      surfaces here.
    * the **inner** handler's partial-delivery branch, which returns
      `{:discard, "Partial delivery failure: N of M failed"}` when any
      recipient's send fails — a shape nothing else in the suite locks in.
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

  describe "outer Worker → inner EmailWorker end-to-end chain" do
    test "diffs, bumps ical_sequence, enqueues the job, and the job renders + delivers" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Title diff drives recipient resolution — the retained attendee is the
      # one recipient fanned out to in the :update dispatch.
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "New Title",
          attendees: [%{"email" => "retained@example.com"}],
          ical_sequence: 4,
          last_notified_state: %{
            "title" => "Old Title",
            "attendees" => ["retained@example.com"]
          }
        )

      expected_uid = event.uid
      organizer_email = user.email

      # The mock pattern-matches the shape of `details` — a field rename in
      # `build_update_details/4` or a key rename in the scheduler's args
      # surfaces here before reaching production.
      expect(EmailServiceMock, :send_event_update_notification, fn email, details ->
        assert email == "retained@example.com"

        assert %{
                 event_title: "New Title",
                 event_uid: ^expected_uid,
                 organizer_email: ^organizer_email,
                 changes: [_change | _rest],
                 method: :request,
                 sequence: 5
               } = details

        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(AttendeeWorker, %{
                 "event_id" => event.id,
                 "kind" => "provider_calendar_event",
                 "action" => "update"
               })

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
      # the dispatch — a retry after a crash doesn't re-notify.
      {:ok, reloaded} = ProviderCalendarEventQueries.fetch(event.id)
      assert reloaded.ical_sequence == 5
      assert reloaded.last_notified_state["title"] == "New Title"

      # Feed the producer's own args into the consumer — if the two halves
      # disagree on arg shape, this is where it surfaces.
      assert :ok = perform_job(EmailWorker, job.args)
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

      expected_uid = event.uid

      # Pattern-matching in the mock ensures a regression in
      # `build_update_details/4` (e.g. missing `changes` or wrong `method`)
      # fails the test rather than silently passing.
      expect(EmailServiceMock, :send_event_update_notification, 2, fn email, details ->
        assert email in ["a@example.com", "b@example.com"]

        assert %{
                 event_title: "New Title",
                 event_uid: ^expected_uid,
                 changes: [_change | _rest],
                 method: :request,
                 sequence: 2
               } = details

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
