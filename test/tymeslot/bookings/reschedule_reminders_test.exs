defmodule Tymeslot.Bookings.RescheduleRemindersTest do
  @moduledoc """
  A moved booking's reminders are settled in the reschedule's transaction:
  cleared for a booking sent back for approval, re-pinned to the new time
  for any other move. A failure refuses the reschedule for a retry, since a
  reminder left at the old time would block the new one and then discard
  itself as overtaken, leaving the booking with none.
  """

  # async: false: the email scheduler is swapped through application config.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  # An email scheduler whose reminder jobs cannot be cleared: the real one
  # returns `:ok` or raises, as the database does.
  defmodule UnclearableReminders do
    @moduledoc false
    @spec cancel_reminder_emails(term()) :: no_return()
    def cancel_reminder_emails(_meeting_id),
      do: raise(DBConnection.ConnectionError, "connection refused")
  end

  # An email scheduler that clears reminders but cannot pin new ones.
  defmodule UnpinnableReminders do
    @moduledoc false
    alias Tymeslot.Emails.EmailScheduler

    defdelegate cancel_reminder_emails(meeting_id), to: EmailScheduler

    @spec schedule_reminder_emails(term(), term(), term(), term()) :: no_return()
    def schedule_reminder_emails(_meeting_id, _value, _unit, _scheduled_at),
      do: raise(DBConnection.ConnectionError, "connection refused")
  end

  # An email scheduler that clears reminders but returns an error, rather
  # than raising, when it cannot pin new ones.
  defmodule RefusingReminders do
    @moduledoc false
    alias Tymeslot.Emails.EmailScheduler

    defdelegate cancel_reminder_emails(meeting_id), to: EmailScheduler

    @spec schedule_reminder_emails(term(), term(), term(), term()) :: {:error, term()}
    def schedule_reminder_emails(_meeting_id, _value, _unit, _scheduled_at),
      do: {:error, :insert_failed}
  end

  defp restore_email_worker(nil), do: Application.delete_env(:tymeslot, :email_worker_module)

  defp restore_email_worker(worker),
    do: Application.put_env(:tymeslot, :email_worker_module, worker)

  defp gated_booking(requires_approval) do
    %{user: user} = create_always_bookable_profile()

    meeting_type =
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        requires_approval: requires_approval,
        approval_window_hours: 12
      )

    meeting =
      insert_meeting_for_user(user, %{meeting_type_id: meeting_type.id, status: "confirmed"})

    params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    %{meeting: meeting, params: params}
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "rescheduling" do
    # A reminder left behind would block the one approval pins, then discard
    # itself as overtaken, leaving the booking with none: so a failure to
    # clear it refuses the reschedule, and trying again clears it.
    test "a reschedule whose old reminders cannot be cleared is refused, and a retry clears them" do
      %{meeting: meeting, params: params} = gated_booking(true)
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      original_worker = Application.get_env(:tymeslot, :email_worker_module)
      Application.put_env(:tymeslot, :email_worker_module, UnclearableReminders)

      try do
        assert {:error, :failed_to_update_meeting} =
                 Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)
      after
        restore_email_worker(original_worker)
      end

      assert %{status: "confirmed"} = reload(meeting)

      assert {:ok, %{status: "awaiting_approval"}} =
               Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end

    # An ordinary move re-pins its reminders in the same transaction: a
    # reminder left at the old time would block the new one and discard
    # itself as overtaken, leaving the booking with none.
    test "an ordinary move whose reminders cannot be re-pinned is refused, and a retry re-pins them" do
      %{meeting: meeting, params: params} = gated_booking(false)
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")
      [old] = all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      original_worker = Application.get_env(:tymeslot, :email_worker_module)
      Application.put_env(:tymeslot, :email_worker_module, UnpinnableReminders)

      try do
        assert {:error, :failed_to_update_meeting} =
                 Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)
      after
        restore_email_worker(original_worker)
      end

      assert DateTime.compare(reload(meeting).start_time, meeting.start_time) == :eq

      assert [%{id: id}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      assert id == old.id

      assert {:ok, moved} = Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)

      assert [pinned] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      assert pinned.args["start_time"] == DateTime.to_iso8601(moved.start_time)
    end

    # The same refusal when the pin fails by returning an error: the nested
    # rollback must still undo the move and the cleared reminder together.
    test "an ordinary move whose reminders return an error is refused, and a retry re-pins them" do
      %{meeting: meeting, params: params} = gated_booking(false)
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")
      [old] = all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      original_worker = Application.get_env(:tymeslot, :email_worker_module)
      Application.put_env(:tymeslot, :email_worker_module, RefusingReminders)

      try do
        assert {:error, :failed_to_update_meeting} =
                 Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)
      after
        restore_email_worker(original_worker)
      end

      assert DateTime.compare(reload(meeting).start_time, meeting.start_time) == :eq

      assert [%{id: id}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      assert id == old.id

      assert {:ok, moved} = Reschedule.execute(meeting.uid, params, meeting.organizer_user_id)

      assert [pinned] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

      assert pinned.args["start_time"] == DateTime.to_iso8601(moved.start_time)
    end
  end
end
