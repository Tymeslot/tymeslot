defmodule Tymeslot.Bookings.CancelExternalCascadeTest do
  @moduledoc """
  Parity tests: `Bookings.Cancel.execute_external/1` must fire the same
  notification cascade (email + webhook + Telegram) as `execute/1`, and must
  only skip the provider-side calendar deletion job — since the external
  deletion is what triggered the cancellation, re-issuing a delete request
  would be redundant and potentially error at the provider.

  Locks in the invariant so a future refactor of `Cancel` cannot silently
  drop webhook, Telegram, or email notifications on externally-triggered
  cancellations.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.TelegramWorker
  alias Tymeslot.Workers.WebhookWorker

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_email_mocks()
    :ok
  end

  describe "execute/1 (internal cancellation)" do
    test "enqueues email, webhook, Telegram, and calendar-deletion jobs" do
      {_user, meeting} = setup_user_meeting_with_automations()

      assert {:ok, _cancelled} = Cancel.execute(meeting)

      assert [email_job] = all_enqueued(worker: EmailWorker)
      assert email_job.args["action"] == "send_cancellation_emails"
      assert email_job.args["meeting_id"] == meeting.id

      assert [webhook_job] = all_enqueued(worker: WebhookWorker)
      assert webhook_job.args["event_type"] == "meeting.cancelled"
      assert webhook_job.args["meeting_id"] == meeting.id

      assert [telegram_job] = all_enqueued(worker: TelegramWorker)
      assert telegram_job.args["event_type"] == "meeting.cancelled"
      assert telegram_job.args["meeting_id"] == meeting.id

      assert [calendar_job] = all_enqueued(worker: CalendarEventWorker)
      assert calendar_job.args["action"] == "delete"
      assert calendar_job.args["meeting_id"] == meeting.id
    end
  end

  describe "execute_external/1 (provider-triggered cancellation)" do
    test "enqueues email, webhook, and Telegram jobs" do
      {_user, meeting} = setup_user_meeting_with_automations()

      assert {:ok, _cancelled} = Cancel.execute_external(meeting)

      assert [email_job] = all_enqueued(worker: EmailWorker)
      assert email_job.args["action"] == "send_cancellation_emails"
      assert email_job.args["meeting_id"] == meeting.id

      assert [webhook_job] = all_enqueued(worker: WebhookWorker)
      assert webhook_job.args["event_type"] == "meeting.cancelled"
      assert webhook_job.args["meeting_id"] == meeting.id

      assert [telegram_job] = all_enqueued(worker: TelegramWorker)
      assert telegram_job.args["event_type"] == "meeting.cancelled"
      assert telegram_job.args["meeting_id"] == meeting.id
    end

    test "does NOT schedule provider-side calendar deletion" do
      {_user, meeting} = setup_user_meeting_with_automations()

      assert {:ok, _cancelled} = Cancel.execute_external(meeting)

      assert all_enqueued(worker: CalendarEventWorker) == []
    end

    test "deletes pending reminder email jobs" do
      {_user, meeting} = setup_user_meeting_with_automations()

      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      assert {:ok, _cancelled} = Cancel.execute_external(meeting)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end

    test "records a cancellation reason distinguishing external origin" do
      {_user, meeting} = setup_user_meeting_with_automations()

      assert {:ok, cancelled} = Cancel.execute_external(meeting)
      assert cancelled.status == "cancelled"
      assert %DateTime{} = cancelled.cancelled_at
      assert cancelled.cancellation_reason == "Cancelled externally via calendar sync"
    end

    test "returns {:ok, meeting} without side effects when called on an already-cancelled meeting" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user, status: "cancelled")
      insert(:webhook, user: user, events: ["meeting.cancelled"])
      insert(:telegram_integration, user: user, events: ["meeting.cancelled"])

      assert {:ok, _result} = Cancel.execute_external(meeting)

      assert all_enqueued(worker: EmailWorker) == []
      assert all_enqueued(worker: WebhookWorker) == []
      assert all_enqueued(worker: TelegramWorker) == []
      assert all_enqueued(worker: CalendarEventWorker) == []
    end

    test "returns {:ok, meeting} without side effects for a confirmed meeting with a pending reschedule request" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          organizer_user: user,
          status: "confirmed",
          reschedule_requested_at: DateTime.utc_now()
        )

      insert(:webhook, user: user, events: ["meeting.cancelled"])
      insert(:telegram_integration, user: user, events: ["meeting.cancelled"])

      assert {:ok, result} = Cancel.execute_external(meeting)
      assert result.status == "confirmed"

      assert all_enqueued(worker: EmailWorker) == []
      assert all_enqueued(worker: WebhookWorker) == []
      assert all_enqueued(worker: TelegramWorker) == []
      assert all_enqueued(worker: CalendarEventWorker) == []
    end
  end

  describe "parity between execute/1 and execute_external/1" do
    test "both paths fan out to the same number of notification jobs" do
      {_user_a, meeting_a} = setup_user_meeting_with_automations()
      {_user_b, meeting_b} = setup_user_meeting_with_automations()

      assert {:ok, _internal} = Cancel.execute(meeting_a)
      assert {:ok, _external} = Cancel.execute_external(meeting_b)

      assert count_jobs_for(EmailWorker, meeting_a.id) == 1
      assert count_jobs_for(EmailWorker, meeting_b.id) == 1

      assert count_jobs_for(EmailWorker, meeting_a.id) ==
               count_jobs_for(EmailWorker, meeting_b.id)

      assert count_jobs_for(WebhookWorker, meeting_a.id) == 1
      assert count_jobs_for(WebhookWorker, meeting_b.id) == 1

      assert count_jobs_for(WebhookWorker, meeting_a.id) ==
               count_jobs_for(WebhookWorker, meeting_b.id)

      assert count_jobs_for(TelegramWorker, meeting_a.id) == 1
      assert count_jobs_for(TelegramWorker, meeting_b.id) == 1

      assert count_jobs_for(TelegramWorker, meeting_a.id) ==
               count_jobs_for(TelegramWorker, meeting_b.id)

      # The one legitimate asymmetry: only internal cancellation schedules the
      # provider-side calendar deletion.
      assert count_jobs_for(CalendarEventWorker, meeting_a.id) == 1
      assert count_jobs_for(CalendarEventWorker, meeting_b.id) == 0
    end
  end

  defp setup_user_meeting_with_automations do
    user = insert(:user)
    meeting = insert(:meeting, organizer_user: user)
    insert(:webhook, user: user, events: ["meeting.cancelled"])
    insert(:telegram_integration, user: user, events: ["meeting.cancelled"])
    {user, meeting}
  end

  defp count_jobs_for(worker, meeting_id) do
    [worker: worker]
    |> all_enqueued()
    |> Enum.count(fn job -> job.args["meeting_id"] == meeting_id end)
  end
end
