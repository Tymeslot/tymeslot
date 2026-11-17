defmodule Tymeslot.Meetings.EmailVerificationTest do
  @moduledoc """
  The email verification gate: which meeting types it applies to, how long a
  booking is held, and every way a held booking leaves the gate. Verifying
  must start exactly what an ungated booking starts; expiring and releasing
  must start nothing at all, since nobody but the attendee knew of it.
  """

  # async: false: the enqueue-failure case patches Oban.insert/1 with :meck,
  # which replaces the module for every process, and the silence checks read
  # Swoosh's shared test process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [where: 2]
  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers
  import Tymeslot.WorkerTestHelpers

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  describe "required?/1" do
    test "reads the type" do
      assert EmailVerification.required?(%{requires_email_verification: true})
      refute EmailVerification.required?(%{requires_email_verification: false})
      refute EmailVerification.required?(nil)
    end
  end

  describe "deadline_for/2" do
    test "the hold is 30 minutes" do
      assert EmailVerification.deadline_for(~U[2026-11-12 10:00:00Z], ~U[2026-11-13 10:00:00Z]) ==
               ~U[2026-11-12 10:30:00Z]
    end

    test "the hold never outlasts the meeting's start" do
      assert EmailVerification.deadline_for(~U[2026-11-12 10:00:00Z], ~U[2026-11-12 10:10:00Z]) ==
               ~U[2026-11-12 10:10:00Z]
    end
  end

  describe "gate_attributes/2" do
    test "gate attributes leave approval unstamped" do
      now = ~U[2026-11-12 10:00:00Z]

      assert EmailVerification.gate_attributes(now, ~U[2026-11-13 10:00:00Z]) == %{
               status: :awaiting_verification,
               verification_deadline_at: ~U[2026-11-12 10:30:00Z],
               approval_requested_at: nil,
               approval_deadline_at: nil
             }
    end
  end

  describe "verify/1" do
    @describetag :integration

    setup do
      TestMocks.stub_no_calendar_events()
      user = insert(:user)
      insert(:profile, user: user)
      %{user: user}
    end

    test "verifying confirms the booking and starts every effect", %{user: user} do
      type = insert(:meeting_type, user: user)
      integration = insert(:video_integration, user: user)

      meeting =
        held(user,
          meeting_type_id: type.id,
          video_integration_id: integration.id,
          reminders: [%{"value" => 1, "unit" => "hours"}]
        )

      :ok = EmailVerificationJobs.schedule_expiry(meeting)

      assert {:ok, :verified, %{status: :confirmed} = verified} =
               EmailVerification.verify(meeting)

      assert %DateTime{} = reload(meeting).email_verified_at

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: EmailVerificationExpiryWorker)

      # The room job announces the booking once it has made the room.
      assert [%{args: room_args}] = all_enqueued(worker: VideoRoomWorker)
      expect_mirotalk_success()
      assert :ok = perform_job(VideoRoomWorker, room_args)

      assert %DateTime{} = reload(verified).first_announced_at

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end

    test "verifying on an approval type sends the request and starts the window now", %{
      user: user
    } do
      type = insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 24)
      created_at = DateTime.utc_now(:second)
      start_time = DateTime.add(created_at, 3, :day)

      meeting =
        held(user,
          meeting_type_id: type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          verification_deadline_at: DateTime.add(created_at, 30, :minute)
        )

      verified_at = DateTime.add(created_at, 20, :minute)
      freeze_clock(verified_at)

      assert {:ok, :verified, verified} = EmailVerification.verify(meeting)

      assert %{status: :awaiting_approval} = verified
      assert verified.approval_requested_at == verified_at
      assert verified.approval_deadline_at == DateTime.add(verified_at, 24, :hour)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => meeting.id}
      )

      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"})
    end

    test "a second verification is idempotent", %{user: user} do
      meeting = held(user)

      assert {:ok, :verified, verified} = EmailVerification.verify(meeting)
      jobs = all_enqueued([])

      # Both the fresh row and a copy read before the first verification.
      assert {:ok, :already_verified, %{id: id}} = EmailVerification.verify(verified)
      assert {:ok, :already_verified, %{id: ^id}} = EmailVerification.verify(meeting)

      assert length(all_enqueued([])) == length(jobs)
    end

    test "a verification after the deadline expires the booking", %{user: user} do
      meeting = held(user, verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60))

      assert {:error, :expired} = EmailVerification.verify(meeting)
      assert reload(meeting).status == :expired

      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: VideoRoomWorker)
      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: ApprovalExpiryWorker)
    end

    test "the deadline itself counts as passed", %{user: user} do
      deadline = DateTime.add(DateTime.utc_now(:second), 10, :minute)
      meeting = held(user, verification_deadline_at: deadline)
      freeze_clock(deadline)

      assert {:error, :expired} = EmailVerification.verify(meeting)
      assert reload(meeting).status == :expired
    end

    # The deadline is read from the row inside the transaction, not from the
    # caller's copy, which may have been read before the hold was shortened.
    test "the deadline is read from the stored booking, not the caller's copy", %{user: user} do
      meeting = held(user)

      Repo.update_all(where(MeetingSchema, id: ^meeting.id),
        set: [verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)]
      )

      assert {:error, :expired} = EmailVerification.verify(meeting)
      assert %{status: :expired, email_verified_at: nil} = reload(meeting)
      refute_enqueued(worker: CalendarEventWorker)
    end

    test "a booking released before verification stays released", %{user: user} do
      meeting = held(user)
      {:ok, _released} = EmailVerification.release(meeting)

      assert {:error, :expired} = EmailVerification.verify(reload(meeting))
      assert {:error, :expired} = EmailVerification.verify(meeting)
      assert reload(meeting).status == :cancelled
    end

    test "verifying without a video room announces the booking to integrations", %{user: user} do
      insert(:webhook, user: user, events: ["meeting.created"])
      meeting = held(user)

      assert {:ok, :verified, _verified} = EmailVerification.verify(meeting)

      assert_enqueued(
        worker: WebhookWorker,
        args: %{"event_type" => "meeting.created", "meeting_id" => meeting.id}
      )

      assert %DateTime{} = reload(meeting).first_announced_at
    end

    test "an expiry that loses to a verification reports the booking as verified", %{
      user: user
    } do
      meeting = held(user)
      {:ok, :verified, _verified} = EmailVerification.verify(meeting)

      # A copy read while still held, arriving after the deadline.
      stale = %{meeting | verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)}

      assert {:ok, :already_verified, %{status: :confirmed}} = EmailVerification.verify(stale)
      assert reload(meeting).status == :confirmed
    end

    test "a booking verified and later cancelled reads as expired", %{user: user} do
      meeting = held(user)
      {:ok, :verified, verified} = EmailVerification.verify(meeting)
      Repo.update_all(where(MeetingSchema, id: ^meeting.id), set: [status: :cancelled])

      assert {:error, :expired} = EmailVerification.verify(verified)
    end

    test "an enqueue failure rolls back and keeps the hold", %{user: user} do
      meeting = held(user)

      refusing_confirmation(fn ->
        assert {:error, :not_scheduled} = quietly(fn -> EmailVerification.verify(meeting) end)
      end)

      assert %{status: :awaiting_verification, email_verified_at: nil, announced_at: nil} =
               reload(meeting)

      refute_enqueued(worker: CalendarEventWorker)

      assert {:ok, :verified, %{status: :confirmed}} = EmailVerification.verify(meeting)
    end
  end

  describe "expire/1 and release/1" do
    @describetag :integration

    setup do
      TestMocks.stub_no_calendar_events()

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
        {:error, :no_integration}
      end)

      Application.put_env(:swoosh, :shared_test_process, self())
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

      on_exit(fn ->
        Application.delete_env(:swoosh, :shared_test_process)
        Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      end)

      %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
      type = insert(:meeting_type, user: user, duration_minutes: 60)
      insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])

      date = Date.add(Date.utc_today(), 1)
      start_time = DateTime.new!(date, ~T[14:00:00], "America/New_York")
      start_time = DateTime.shift_zone!(start_time, "Etc/UTC")

      meeting =
        held(user,
          meeting_type_id: type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          duration: 60
        )

      :ok = EmailVerificationJobs.schedule_expiry(meeting)

      params = %{
        date: date,
        time: "14:00",
        duration: "60min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id,
        meeting_type_id: type.id
      }

      %{meeting: meeting, params: params}
    end

    test "expiry releases the slot and tells nobody", %{meeting: meeting, params: params} do
      form = %{"name" => "Someone Else", "email" => "else@example.com", "message" => ""}

      # Held, the slot is taken.
      assert {:error, _taken} = quietly(fn -> Create.execute(params, form) end)

      assert {:ok, %{status: :expired, cancelled_at: %DateTime{}}} =
               EmailVerification.expire(meeting)

      assert reload(meeting).status == :expired
      refute_enqueued(worker: EmailVerificationExpiryWorker)
      refute_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: CalendarEventWorker)

      Oban.drain_queue(queue: :emails)
      refute_received {:email, _email}

      assert {:ok, %{status: :confirmed}} = Create.execute(params, form)
    end

    test "expiring twice is refused the second time", %{meeting: meeting} do
      assert {:ok, _expired} = EmailVerification.expire(meeting)
      assert {:error, :not_awaiting_verification} = EmailVerification.expire(meeting)
    end

    test "releasing cancels the booking, frees the slot and tells nobody", %{
      meeting: meeting,
      params: params
    } do
      assert {:ok, %{status: :cancelled, cancelled_at: %DateTime{}}} =
               EmailVerification.release(meeting)

      refute_enqueued(worker: EmailVerificationExpiryWorker)
      refute_enqueued(worker: WebhookWorker)
      Oban.drain_queue(queue: :emails)
      refute_received {:email, _email}

      assert {:error, :not_awaiting_verification} = EmailVerification.release(meeting)

      form = %{"name" => "Someone Else", "email" => "else@example.com", "message" => ""}
      assert {:ok, %{status: :confirmed}} = Create.execute(params, form)
    end
  end

  describe "prune_unverified/1" do
    setup do
      %{user: insert(:user)}
    end

    test "a never-verified booking is deleted a day after its deadline", %{user: user} do
      expired = lapsed(user, :expired, 25)
      released = lapsed(user, :cancelled, 25)

      {:ok, guest} =
        GuestQueries.insert_guest(%{meeting_id: expired.id, email: "guest@example.com"})

      assert {2, _rows} = EmailVerification.prune_unverified()

      refute Repo.get(MeetingSchema, expired.id)
      refute Repo.get(MeetingSchema, released.id)
      refute Repo.get(GuestSchema, guest.id)
    end

    test "a recent or verified booking is kept", %{user: user} do
      now = DateTime.utc_now(:second)

      recent = lapsed(user, :expired, 23)
      recent_released = lapsed(user, :cancelled, 23)

      verified_expired =
        lapsed(user, :expired, 25, email_verified_at: DateTime.add(now, -26, :hour))

      verified_cancelled =
        lapsed(user, :cancelled, 25, email_verified_at: DateTime.add(now, -26, :hour))

      held = held(user, verification_deadline_at: DateTime.add(now, -25, :hour))
      ungated = insert(:meeting, organizer_user_id: user.id, status: :expired)

      assert {0, _rows} = EmailVerification.prune_unverified()

      for meeting <- [
            recent,
            recent_released,
            verified_expired,
            verified_cancelled,
            held,
            ungated
          ] do
        assert Repo.get(MeetingSchema, meeting.id), "#{meeting.id} should have been kept"
      end
    end

    test "the retention window can be given in hours", %{user: user} do
      meeting = lapsed(user, :expired, 3)

      assert {0, _rows} = EmailVerification.prune_unverified(4)
      assert {1, _rows} = EmailVerification.prune_unverified(2)
      refute Repo.get(MeetingSchema, meeting.id)
    end
  end

  describe "resend/1" do
    setup do
      user = insert(:user)
      %{meeting: held(user)}
    end

    test "sends the email again, numbered as the second send", %{meeting: meeting} do
      deadline = meeting.verification_deadline_at

      assert {:ok, %{verification_emails_sent: 2, verification_deadline_at: ^deadline}} =
               EmailVerification.resend(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_booking_email_verification",
          "meeting_id" => meeting.id,
          "send" => 2
        }
      )
    end

    test "counts down the resends left, to zero at the cap", %{meeting: meeting} do
      assert EmailVerification.resends_left(meeting) == 3

      lefts =
        for _resend <- 1..3 do
          {:ok, counted} = EmailVerification.resend(meeting)
          EmailVerification.resends_left(counted)
        end

      assert lefts == [2, 1, 0]
    end

    test "allows three resends and refuses the fourth", %{meeting: meeting} do
      for _resend <- 1..3, do: assert({:ok, _counted} = EmailVerification.resend(meeting))

      assert {:error, :limit_reached} = EmailVerification.resend(meeting)

      sends =
        [worker: EmailWorker, args: %{"action" => "send_booking_email_verification"}]
        |> all_enqueued()
        |> Enum.map(& &1.args["send"])
        |> Enum.sort()

      assert sends == [2, 3, 4]
      assert reload(meeting).verification_emails_sent == 4
    end

    test "after the deadline it releases the booking instead", %{meeting: meeting} do
      freeze_clock(meeting.verification_deadline_at)

      assert {:error, :expired} = EmailVerification.resend(meeting)
      assert reload(meeting).status == :expired
      refute_enqueued(worker: EmailWorker)
    end

    test "a booking no longer held is refused", %{meeting: meeting} do
      {:ok, _released} = EmailVerification.release(meeting)

      assert {:error, :not_awaiting_verification} = EmailVerification.resend(meeting)
      refute_enqueued(worker: EmailWorker)
    end

    test "an enqueue failure leaves the count where it was", %{meeting: meeting} do
      refusing("send_booking_email_verification", fn ->
        assert {:error, :not_scheduled} = quietly(fn -> EmailVerification.resend(meeting) end)
      end)

      assert reload(meeting).verification_emails_sent == nil
    end
  end

  # On a meeting type of the organiser's own unless `attrs` names one: a held
  # booking whose type is gone is never confirmed.
  defp held(user, attrs \\ []) do
    defaults = [
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: nil
    ]

    attrs =
      Keyword.put_new_lazy(attrs, :meeting_type_id, fn ->
        insert(:meeting_type, user: user).id
      end)

    insert(:awaiting_verification_meeting, Keyword.merge(defaults, attrs))
  end

  # A booking that left the gate without being confirmed (`status` is
  # `:expired` or `:cancelled`), whose deadline passed `hours_ago` hours ago.
  defp lapsed(user, status, hours_ago, attrs \\ []) do
    held(
      user,
      Keyword.merge(
        [
          status: status,
          verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -hours_ago, :hour)
        ],
        attrs
      )
    )
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp refusing_confirmation(fun), do: refusing("send_confirmation_emails", fun)

  # Every insert of an email job with this action reports a failure; other
  # jobs insert.
  defp refusing(action, fun) do
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == action,
        do: {:error, :queue_not_available},
        else: :meck.passthrough([changeset])
    end)

    try do
      fun.()
    after
      :meck.unload(Oban)
    end
  end
end
