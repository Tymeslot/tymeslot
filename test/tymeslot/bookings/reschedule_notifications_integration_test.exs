defmodule Tymeslot.Bookings.RescheduleNotificationsIntegrationTest do
  @moduledoc """
  End-to-end coverage of the notification half of `Reschedule.execute/4`, run
  against the **real** email service rather than the Mox double.

  Issue #76: the reschedule payload was built by a different builder than the
  one every email template is written against, so rendering the attendee email
  raised a `KeyError` on a key the payload never carried. The raise escaped
  `Notifications.Events.meeting_rescheduled/2` before it reached the webhook,
  Telegram and Slack dispatches, so an attendee rescheduling through their own
  link silently lost every downstream channel — and the booking LiveView died
  on the error instead of rendering the confirmation.

  Mocking the email service is exactly what hid it: the templates never ran.
  These tests render for real, and pin the containment that keeps one failed
  channel from silencing the rest.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Oban.Job
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.TelegramWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  # Stands in for any template failure the payload can provoke: the send path
  # raises rather than returning `{:error, _}`, which is what made issue #76
  # take the other channels down with it.
  defmodule RaisingEmailService do
    @spec send_reschedule_emails(map()) :: no_return()
    def send_reschedule_emails(_content) do
      raise KeyError, key: :reminders_summary, term: %{}
    end
  end

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_email_mocks()

    # The real service, so the templates actually render. Restored afterwards
    # for the rest of the suite.
    original_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    # `Delivery.deliver/1` runs inside the circuit-breaker GenServer, so
    # Swoosh's test adapter would otherwise post `{:email, _}` to that process
    # rather than to this one. Pointing the adapter at this test collects the
    # rendered emails here instead. Safe because the module is `async: false`:
    # no other test runs while these do.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, original_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")

    # The booking policy lives on the schedule now, not the profile; these tests
    # only need one to exist so the reschedule resolves a policy at all. It
    # must offer every hour of every day: reschedule now refuses a time the
    # organiser's schedule doesn't offer, and these tests pick
    # `future_datetime/2`, an arbitrary time of day.
    schedule =
      insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 15)

    for day_of_week <- 1..7 do
      {:ok, _day} =
        WeeklySchedule.create_day_availability(schedule.id, day_of_week, %{
          is_available: true,
          start_time: ~T[00:00:00],
          end_time: ~T[23:59:00]
        })
    end

    insert(:webhook, user: user, events: ["meeting.rescheduled"])
    insert(:telegram_integration, user: user, events: ["meeting.rescheduled"])

    meeting = insert_future_meeting(user)

    %{user: user, profile: profile, meeting: meeting}
  end

  describe "execute/4 with the real email service" do
    test "renders and delivers a reschedule email to each party", %{user: user, meeting: meeting} do
      new_params = reschedule_params_for(future_datetime(5, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      delivered = delivered_emails()

      assert delivered[meeting.organizer_email].subject =~ "Rescheduled"
      assert delivered[meeting.attendee_email].subject =~ "Rescheduled"
    end

    test "both emails state the slot the meeting moved away from", %{
      user: user,
      meeting: meeting
    } do
      original_start = meeting.start_time
      new_params = reschedule_params_for(future_datetime(6, :day))

      assert {:ok, updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)
      refute DateTime.compare(updated.start_time, original_start) == :eq

      delivered = delivered_emails()

      assert delivered[meeting.attendee_email].text_body =~ "Previously scheduled for"
      assert delivered[meeting.organizer_email].text_body =~ "Previously scheduled for"
    end

    test "the attendee email carries a SEQUENCE-bumped ICS so calendars replace the old slot",
         %{user: user, meeting: meeting} do
      new_params = reschedule_params_for(future_datetime(10, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      attendee_email = delivered_emails()[meeting.attendee_email]

      assert ics = Enum.find(attendee_email.attachments, &(&1.content_type =~ "text/calendar"))
      assert ics.data =~ "SEQUENCE:1"
    end

    test "dispatches the meeting.rescheduled webhook alongside the emails", %{
      user: user,
      meeting: meeting
    } do
      new_params = reschedule_params_for(future_datetime(7, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [%{args: %{"event_type" => "meeting.rescheduled", "meeting_id" => meeting_id}}] =
               all_enqueued(worker: WebhookWorker)

      assert meeting_id == meeting.id
    end
  end

  describe "execute/4 re-arms a reminder that already fired" do
    test "schedules a fresh reminder for the new time, even though the previous reminder already completed",
         %{user: user, meeting: meeting} do
      assert :ok = Orchestrator.schedule_reminder_notifications(meeting)

      assert [%{id: reminder_job_id}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      # Simulate the reminder having already fired, as it will have for any
      # reschedule that happens after the original reminder's send time.
      {1, nil} =
        Repo.update_all(from(j in Job, where: j.id == ^reminder_job_id),
          set: [state: "completed", completed_at: DateTime.utc_now()]
        )

      new_params = reschedule_params_for(future_datetime(11, :day))
      assert {:ok, updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [%{scheduled_at: new_scheduled_at, state: "scheduled"} = new_job] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      refute new_job.id == reminder_job_id
      assert DateTime.compare(new_scheduled_at, updated.start_time) == :lt
    end
  end

  describe "execute/4 when the email send fails" do
    setup do
      Application.put_env(:tymeslot, :email_service_module, RaisingEmailService)
      :ok
    end

    test "still dispatches the webhook and Telegram jobs", %{user: user, meeting: meeting} do
      new_params = reschedule_params_for(future_datetime(8, :day))

      assert {:ok, _updated} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)

      assert [%{args: %{"event_type" => "meeting.rescheduled", "meeting_id" => meeting_id}}] =
               all_enqueued(worker: WebhookWorker)

      assert meeting_id == meeting.id

      assert [%{args: %{"event_type" => "meeting.rescheduled"}}] =
               all_enqueued(worker: TelegramWorker)
    end

    test "still persists the new meeting time", %{user: user, meeting: meeting} do
      target = future_datetime(9, :day)

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, reschedule_params_for(target), %{}, user.id)

      refute DateTime.compare(updated.start_time, meeting.start_time) == :eq
    end
  end

  # ----- helpers -----

  # The two emails a reschedule sends, keyed by recipient address, so a test
  # names the one it means instead of depending on delivery order.
  defp delivered_emails do
    assert_received {:email, first}
    assert_received {:email, second}

    Map.new([first, second], fn email ->
      {email.to |> hd() |> elem(1), email}
    end)
  end

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

  # Floored to the half hour: the open schedule's slots are generated in
  # 30-minute steps from local midnight, so an unaligned current-time
  # minute/second would land between slots and the reschedule's own
  # schedule check (`Bookings.ScheduleCheck`) would refuse it.
  defp future_datetime(amount, unit) do
    DateTime.utc_now()
    |> DateTime.add(amount, unit)
    |> DateTime.truncate(:second)
    |> floor_to_half_hour()
  end

  defp floor_to_half_hour(%DateTime{minute: minute} = dt) do
    %{dt | minute: minute - rem(minute, 30), second: 0, microsecond: {0, 0}}
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

  defp time_string(%DateTime{hour: hour, minute: minute}) do
    "#{pad(hour)}:#{pad(minute)}"
  end

  defp pad(number) when number < 10, do: "0#{number}"
  defp pad(number), do: Integer.to_string(number)
end
