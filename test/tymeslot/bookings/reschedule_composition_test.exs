defmodule Tymeslot.Bookings.RescheduleCompositionTest do
  @moduledoc """
  Composition tests for `Tymeslot.Bookings.Reschedule.execute/4`. The
  existing `reschedule_test.exs` covers the success/policy/validation
  branches on the meeting row itself; this module fills the job-chain
  gap — a successful reschedule must enqueue the downstream
  CalendarEventWorker ("update") and webhook/Telegram jobs, and a
  conflict must roll back the time write rather than silently leaving
  the meeting in the new slot.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  setup :verify_on_exit!

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Webhooks.WebhookSchema
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.TelegramWorker
  alias Tymeslot.Workers.WebhookWorker

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_email_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")
    insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 15)
    insert(:webhook, user: user, events: ["meeting.rescheduled"])
    insert(:telegram_integration, user: user, events: ["meeting.rescheduled"])

    meeting = insert_future_meeting(user)

    %{user: user, profile: profile, meeting: meeting}
  end

  describe "execute/4 success chain" do
    test "persists the new time and enqueues the calendar update job", %{
      user: user,
      meeting: meeting
    } do
      new_params = reschedule_params_for(future_datetime(5, :day))

      assert {:ok, updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert updated.id == meeting.id
      refute DateTime.compare(updated.start_time, meeting.start_time) == :eq

      assert [calendar_job] = all_enqueued(worker: CalendarEventWorker)
      assert calendar_job.args["action"] == "update"
      assert calendar_job.args["meeting_id"] == meeting.id
    end

    test "enqueues webhook and Telegram jobs for reschedule", %{
      user: user,
      meeting: meeting
    } do
      new_params = reschedule_params_for(future_datetime(5, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [webhook_job] = all_enqueued(worker: WebhookWorker)
      assert webhook_job.args["event_type"] == "meeting.rescheduled"
      assert webhook_job.args["meeting_id"] == meeting.id

      assert [telegram_job] = all_enqueued(worker: TelegramWorker)
      assert telegram_job.args["event_type"] == "meeting.rescheduled"
      assert telegram_job.args["meeting_id"] == meeting.id
    end
  end

  describe "execute/4 full cascade parity" do
    # Reschedule's public guarantee is that every channel the user has
    # configured for meeting changes fires exactly once: calendar
    # provider, email recipients, webhook subscribers, Telegram chat.
    # Dropping any one of those channels silently (e.g. a refactor that
    # moves Dispatcher.dispatch outside of Events.meeting_rescheduled/2)
    # would be invisible via unit tests but user-breaking. This test
    # pins the union — all four channels surface a reschedule event
    # when the user has opted into each.

    test "fires calendar job + email send + webhook + Telegram in a single execute/4", %{
      user: user,
      meeting: meeting
    } do
      # Over-ride the default stub with a strict expectation so the
      # email channel counts as "observed" alongside the three Oban
      # queues.
      expect(EmailServiceMock, :send_appointment_confirmations, 1, fn _details ->
        {{:ok, :ok}, {:ok, :ok}}
      end)

      new_params = reschedule_params_for(future_datetime(7, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [%{args: %{"action" => "update", "meeting_id" => mid}}] =
               all_enqueued(worker: CalendarEventWorker)

      assert mid == meeting.id

      assert [%{args: %{"event_type" => "meeting.rescheduled", "meeting_id" => ^mid}}] =
               all_enqueued(worker: WebhookWorker)

      assert [%{args: %{"event_type" => "meeting.rescheduled", "meeting_id" => ^mid}}] =
               all_enqueued(worker: TelegramWorker)
    end

    test "with no webhook or Telegram integration the email + calendar channels still fire", %{
      user: user,
      meeting: meeting
    } do
      # Drops the opt-in rows seeded in the top-level setup so the user
      # has only the core email + calendar channels wired. The reschedule
      # must still fire both of those, and must not enqueue phantom
      # webhook/Telegram jobs for channels the user never configured.
      # Sandbox isolation keeps the delete_all scoped to this test.
      Repo.delete_all(WebhookSchema)
      Repo.delete_all(TelegramIntegrationSchema)

      expect(EmailServiceMock, :send_appointment_confirmations, 1, fn _details ->
        {{:ok, :ok}, {:ok, :ok}}
      end)

      new_params = reschedule_params_for(future_datetime(8, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [_calendar_job] = all_enqueued(worker: CalendarEventWorker)
      assert all_enqueued(worker: WebhookWorker) == []
      assert all_enqueued(worker: TelegramWorker) == []
    end
  end

  describe "execute/4 rollback" do
    test "rolls back the time update when the new slot conflicts with another meeting", %{
      user: user,
      meeting: meeting
    } do
      blocker_start = future_datetime(5, :day)
      _blocker = insert_meeting_at(user, blocker_start)

      original_start = meeting.start_time
      new_params = reschedule_params_for(blocker_start)

      assert {:error, _reason} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      {:ok, reloaded} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert DateTime.compare(reloaded.start_time, original_start) == :eq
      assert all_enqueued(worker: CalendarEventWorker) == []
    end
  end

  # ----- helpers -----

  defp insert_future_meeting(user) do
    start_time = future_datetime(3, :day)

    insert(:meeting,
      uid: UUID.generate(),
      organizer_user_id: user.id,
      organizer_email: "organiser-#{user.id}@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end

  defp insert_meeting_at(user, start_time) do
    insert(:meeting,
      uid: UUID.generate(),
      organizer_user_id: user.id,
      organizer_email: "organiser-#{user.id}@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end

  defp future_datetime(amount, unit) do
    DateTime.utc_now() |> DateTime.add(amount, unit) |> DateTime.truncate(:second)
  end

  defp reschedule_params_for(%DateTime{} = target_utc) do
    in_berlin = DateTime.shift_zone!(target_utc, "Europe/Berlin")

    %{
      date: Date.to_iso8601(DateTime.to_date(in_berlin)),
      time: time_string(in_berlin),
      duration: "30min",
      user_timezone: "Europe/Berlin"
    }
  end

  defp time_string(%DateTime{hour: h, minute: m}) do
    "#{pad(h)}:#{pad(m)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
