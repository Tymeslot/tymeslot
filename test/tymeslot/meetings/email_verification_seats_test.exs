defmodule Tymeslot.Meetings.EmailVerificationSeatsTest do
  @moduledoc """
  The email verification gate for a seat on a group meeting. Verifying a seat
  must start exactly what an ungated seat starts, and bring a slot held for
  verification to life when it is the first to count; expiring a seat must
  start nothing, and void a held slot only once no held seat is left on it.
  """

  # async: false: the room worker's MiroTalk stub and the seat broadcast
  # subscription are process-global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [where: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers, only: [expect_mirotalk_group_success: 0]

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.Bookings.Create
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.Meetings.Workers.EmailVerificationSweepWorker
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    type = insert(:meeting_type, user: user, duration_minutes: 60, max_participants: 3)
    insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])

    date = Date.add(Date.utc_today(), 2)

    start_time =
      date |> DateTime.new!(~T[14:00:00], "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

    params = %{
      date: date,
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: type.id
    }

    %{user: user, type: type, start_time: start_time, params: params}
  end

  describe "verify_seat/1" do
    test "verifying the first seat brings the slot to life", ctx do
      integration = insert(:video_integration, user: ctx.user)

      slot =
        slot(ctx, :awaiting_verification,
          video_integration_id: integration.id,
          reminders: [%{"value" => 1, "unit" => "hours"}]
        )

      seat = held_seat(slot, "first@example.com")
      :ok = EmailVerificationJobs.schedule_seat_expiry(seat)

      assert Meetings.list_upcoming_meetings_for_organizer(ctx.user.id) == []

      assert {:ok, :verified, %MeetingSchema{id: slot_id, status: :confirmed}} =
               EmailVerification.verify_seat(seat)

      assert slot_id == slot.id
      assert %{status: :confirmed, email_verified_at: %DateTime{}} = reload(slot)
      assert %{email_verified_at: %DateTime{}, cancelled_at: nil} = reload(seat)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => slot.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => slot.id}
      )

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => slot.id, "announce" => true}
      )

      assert [%{args: %{"event_type" => "meeting.created"}}] = all_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: EmailVerificationExpiryWorker)

      assert [listed] = Meetings.list_upcoming_meetings_for_organizer(ctx.user.id)
      assert listed.id == slot.id

      assert [%{email: "first@example.com"}] =
               MeetingListQueries.preload_live_participants(listed).participants

      # The room's job releases the seat's confirmation, to the booker and
      # the organiser, once the join link exists.
      expect_mirotalk_group_success()
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => slot.id, "announce" => true})

      confirmation = seat_confirmation_args(slot, seat)
      assert_enqueued(worker: EmailWorker, args: confirmation)

      expect(EmailServiceMock, :send_seat_update_to_organizer, fn :booked, _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn email, _details ->
        assert email == "first@example.com"
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, confirmation)
    end

    test "verifying a later seat adds it to a live slot", ctx do
      slot = slot(ctx, :confirmed)
      first = visible_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      assert {:ok, :verified, %{status: :confirmed}} = EmailVerification.verify_seat(second)

      assert calendar_actions(slot) == ["update"]
      assert_enqueued(worker: EmailWorker, args: seat_confirmation_args(slot, second))
      refute_enqueued(worker: EmailWorker, args: seat_confirmation_args(slot, first))
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})
      refute_enqueued(worker: VideoRoomWorker)
      assert [_one] = all_enqueued(worker: WebhookWorker)
    end

    test "two seats on a held slot verify in turn", ctx do
      slot = slot(ctx, :awaiting_verification)
      first = held_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      assert {:ok, :verified, _slot} = EmailVerification.verify_seat(first)
      assert calendar_actions(slot) == ["create"]

      assert {:ok, :verified, _slot} = EmailVerification.verify_seat(second)
      assert calendar_actions(slot) == ["create", "update"]

      assert_enqueued(worker: EmailWorker, args: seat_confirmation_args(slot, first))
      assert_enqueued(worker: EmailWorker, args: seat_confirmation_args(slot, second))
      assert length(all_enqueued(worker: WebhookWorker)) == 2
    end

    test "a planned session's seat verifies as a later seat", ctx do
      slot = slot(ctx, :confirmed, planned: true)
      seat = held_seat(slot, "first@example.com")

      assert {:ok, :verified, _slot} = EmailVerification.verify_seat(seat)
      assert calendar_actions(slot) == ["update"]
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})
    end

    test "a second verification is idempotent", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")

      assert {:ok, :verified, _slot} = EmailVerification.verify_seat(seat)

      assert {:ok, :already_verified, %{id: slot_id}} = EmailVerification.verify_seat(seat)
      assert slot_id == slot.id
      assert calendar_actions(slot) == ["create"]
    end

    test "a verification at the seat's deadline releases it instead", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com", DateTime.add(DateTime.utc_now(:second), -1))

      assert {:error, :expired} = EmailVerification.verify_seat(seat)
      assert %{cancelled_at: %DateTime{}, email_verified_at: nil} = reload(seat)
      assert reload(slot).status == :expired
      refute_enqueued(worker: CalendarEventWorker)
    end

    test "a seat on a held slot whose meeting type was deleted is released, not confirmed",
         ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")
      :ok = EmailVerificationJobs.schedule_seat_expiry(seat)
      Repo.delete!(ctx.type)

      assert {:error, :expired} = EmailVerification.verify_seat(seat)

      assert %{cancelled_at: %DateTime{}, email_verified_at: nil} = reload(seat)
      assert %{status: :expired, email_verified_at: nil} = reload(slot)
      refute_enqueued(worker: EmailVerificationExpiryWorker)
      assert_nothing_started()
    end

    test "a seat on a live slot whose meeting type was deleted is released, not confirmed",
         ctx do
      slot = slot(ctx, :confirmed)
      visible_seat(slot, "first@example.com")
      seat = held_seat(slot, "second@example.com")
      Repo.delete!(ctx.type)

      assert {:error, :expired} = EmailVerification.verify_seat(reload(seat))

      assert %{cancelled_at: %DateTime{}, email_verified_at: nil} = reload(seat)
      assert reload(slot).status == :confirmed
      assert_nothing_started()
    end

    # A fresh seat on either type would be refused (`:meeting_type_inactive`,
    # `:series_required`), so a held one is not confirmed past the host's
    # change either.
    for {became, changes} <- [
          {"deactivated", [is_active: false]},
          {"series-only",
           [
             series_mode: :recurring,
             series_frequency: :weekly,
             series_interval: 1,
             series_min_occurrences: 2,
             series_max_occurrences: 12,
             series_required: true
           ]}
        ] do
      test "a seat on a held slot whose meeting type was #{became} is released", ctx do
        slot = slot(ctx, :awaiting_verification)
        seat = held_seat(slot, "first@example.com")
        :ok = EmailVerificationJobs.schedule_seat_expiry(seat)

        Repo.update_all(where(MeetingTypeSchema, id: ^ctx.type.id), set: unquote(changes))

        assert {:error, :expired} = EmailVerification.verify_seat(seat)

        assert %{cancelled_at: %DateTime{}, email_verified_at: nil} = reload(seat)
        assert %{status: :expired, email_verified_at: nil} = reload(slot)
        refute_enqueued(worker: EmailVerificationExpiryWorker)
        assert_nothing_started()
      end
    end

    test "a seat verified after its slot was cancelled reads expired", ctx do
      slot = slot(ctx, :confirmed)
      first = visible_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      stub(EmailServiceMock, :send_seat_update_to_organizer, fn _kind, _email, _details ->
        {:ok, "sent"}
      end)

      # The last visible seat leaving cancels the slot and the held seat.
      assert {:ok, :meeting_cancelled} = CancelSeat.execute(first.management_token)
      calendar_before = calendar_actions(slot)

      assert {:error, :expired} = EmailVerification.verify_seat(second)
      assert reload(second).email_verified_at == nil
      assert calendar_actions(slot) == calendar_before
    end

    test "a held seat on a slot no longer occupying its time reads expired", ctx do
      slot = slot(ctx, :cancelled)
      seat = held_seat(slot, "first@example.com")

      assert {:error, :expired} = EmailVerification.verify_seat(seat)
      assert reload(seat).email_verified_at == nil
      refute_enqueued(worker: CalendarEventWorker)
    end
  end

  describe "expire_seat/1" do
    setup ctx do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(ctx.type.id))
      :ok
    end

    test "an expired seat on a held slot voids it silently", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")
      :ok = EmailVerificationJobs.schedule_seat_expiry(seat)

      assert {:ok, %ParticipantSchema{cancelled_at: %DateTime{}}} =
               EmailVerification.expire_seat(seat)

      assert %{status: :expired, cancelled_at: %DateTime{}} = reload(slot)
      assert_receive {:seat_update, _type_id}

      refute_enqueued(worker: EmailVerificationExpiryWorker)
      assert all_enqueued(worker: EmailWorker) == []
      refute_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: CalendarEventWorker)

      form = %{"name" => "Someone Else", "email" => "else@example.com", "message" => ""}
      assert {:ok, %{id: new_slot_id, status: :confirmed}} = Create.execute(ctx.params, form)
      assert new_slot_id != slot.id
    end

    test "an expired seat beside another held seat keeps the slot held", ctx do
      slot = slot(ctx, :awaiting_verification)
      first = held_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      assert {:ok, _expired} = EmailVerification.expire_seat(first)

      assert reload(slot).status == :awaiting_verification
      assert reload(second).cancelled_at == nil
      assert_receive {:seat_update, _type_id}
    end

    test "a held slot past its own deadline outlives it while a seat's hold runs", ctx do
      ago = DateTime.add(DateTime.utc_now(:second), -60)
      slot = slot(ctx, :awaiting_verification, verification_deadline_at: ago)
      first = held_seat(slot, "first@example.com", ago)
      second = held_seat(slot, "second@example.com")
      :ok = EmailVerificationJobs.schedule_expiry(slot)

      assert {:ok, %{expired: 1, skipped: 0, failed: 0}} =
               perform_job(EmailVerificationSweepWorker, %{})

      assert %{cancelled_at: %DateTime{}} = reload(first)
      assert reload(slot).status == :awaiting_verification

      # Neither a stray slot-level job nor a direct release voids it.
      assert {:discard, _reason} =
               perform_job(EmailVerificationExpiryWorker, %{"meeting_id" => slot.id})

      assert {:error, :not_awaiting_verification} = EmailVerification.expire(slot)
      assert {:error, :not_awaiting_verification} = EmailVerification.release(slot)
      assert reload(slot).status == :awaiting_verification

      assert {:ok, _expired} = EmailVerification.expire_seat(second)
      assert reload(slot).status == :expired
    end

    test "an expired seat on a live slot leaves it alone", ctx do
      slot = slot(ctx, :confirmed)
      visible_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      assert {:ok, _expired} = EmailVerification.expire_seat(second)

      assert %{status: :confirmed, cancelled_at: nil} = reload(slot)
      assert %{cancelled_at: %DateTime{}} = reload(second)
      refute_enqueued(worker: CalendarEventWorker)
      assert all_enqueued(worker: EmailWorker) == []
      refute_enqueued(worker: WebhookWorker)
    end

    test "expiring a verified or already released seat is refused", ctx do
      slot = slot(ctx, :confirmed)

      verified =
        visible_seat(slot, "first@example.com", email_verified_at: DateTime.utc_now(:second))

      held = held_seat(slot, "second@example.com")

      assert {:ok, _expired} = EmailVerification.expire_seat(held)
      assert {:error, :not_awaiting_verification} = EmailVerification.expire_seat(held)
      assert {:error, :not_awaiting_verification} = EmailVerification.expire_seat(verified)
      assert reload(verified).cancelled_at == nil
    end
  end

  describe "release_seat/1" do
    setup ctx do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(ctx.type.id))
      :ok
    end

    test "releasing the only held seat voids the slot silently", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")
      :ok = EmailVerificationJobs.schedule_seat_expiry(seat)

      assert {:ok, %ParticipantSchema{cancelled_at: %DateTime{}}} =
               EmailVerification.release_seat(seat)

      assert %{status: :expired, cancelled_at: %DateTime{}} = reload(slot)
      assert_receive {:seat_update, _type_id}
      refute_enqueued(worker: EmailVerificationExpiryWorker)
      assert_nothing_started()
    end

    test "releasing one of two held seats keeps the slot held", ctx do
      slot = slot(ctx, :awaiting_verification)
      first = held_seat(slot, "first@example.com")
      second = held_seat(slot, "second@example.com")

      assert {:ok, _released} = EmailVerification.release_seat(first)

      assert reload(slot).status == :awaiting_verification
      assert %{cancelled_at: %DateTime{}} = reload(first)
      assert reload(second).cancelled_at == nil
      assert_receive {:seat_update, _type_id}
      assert_nothing_started()
    end

    test "releasing a held seat on a live slot leaves the slot alone", ctx do
      slot = slot(ctx, :confirmed)
      visible_seat(slot, "first@example.com")
      held = held_seat(slot, "second@example.com")

      assert {:ok, _released} = EmailVerification.release_seat(held)

      assert %{status: :confirmed, cancelled_at: nil} = reload(slot)
      assert %{cancelled_at: %DateTime{}} = reload(held)
      assert_nothing_started()

      assert {:error, :not_awaiting_verification} = EmailVerification.release_seat(held)
    end
  end

  describe "resend_seat/1" do
    test "resending a seat's email sends the seat email and keeps the deadline", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")

      assert {:ok, %ParticipantSchema{verification_emails_sent: 2}} =
               EmailVerification.resend_seat(seat)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_seat_email_verification",
          "meeting_id" => slot.id,
          "participant_id" => seat.id,
          "send" => 2
        }
      )

      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_booking_email_verification"})

      assert %{verification_deadline_at: deadline, verification_emails_sent: 2} = reload(seat)
      assert deadline == seat.verification_deadline_at
      assert reload(slot).verification_emails_sent == nil
    end

    test "seat resends stop at the cap", ctx do
      seat = ctx |> slot(:awaiting_verification) |> held_seat("first@example.com")

      for send <- 2..4 do
        assert {:ok, %{verification_emails_sent: ^send}} = EmailVerification.resend_seat(seat)
      end

      assert {:error, :limit_reached} = EmailVerification.resend_seat(seat)
      assert reload(seat).verification_emails_sent == 4
      assert length(all_enqueued(worker: EmailWorker)) == 3
    end

    test "a seat cannot be resent once verified, released or lapsed", ctx do
      slot = slot(ctx, :confirmed)

      verified =
        held_seat(slot, "verified@example.com", nil, email_verified_at: DateTime.utc_now(:second))

      released = held_seat(slot, "released@example.com")
      {:ok, _released} = EmailVerification.release_seat(released)

      lapsed =
        held_seat(slot, "lapsed@example.com", DateTime.add(DateTime.utc_now(:second), -60))

      assert {:error, :not_awaiting_verification} = EmailVerification.resend_seat(verified)
      assert {:error, :not_awaiting_verification} = EmailVerification.resend_seat(released)
      assert {:error, :expired} = EmailVerification.resend_seat(lapsed)
      assert %{cancelled_at: %DateTime{}} = reload(lapsed)

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "a group slot's own email is never resent", ctx do
      slot = slot(ctx, :awaiting_verification)
      held_seat(slot, "first@example.com")

      assert {:error, :not_awaiting_verification} = EmailVerification.resend(slot)
      assert reload(slot).verification_emails_sent == nil
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "prune_unverified/1" do
    test "a seat released without verifying is deleted a day after its deadline", ctx do
      slot = slot(ctx, :confirmed)
      now = DateTime.utc_now(:second)
      visible = visible_seat(slot, "visible@example.com")

      lapsed =
        held_seat(slot, "lapsed@example.com", DateTime.add(now, -25, :hour),
          cancelled_at: DateTime.add(now, -25, :hour)
        )

      recent =
        held_seat(slot, "recent@example.com", DateTime.add(now, -23, :hour),
          cancelled_at: DateTime.add(now, -23, :hour)
        )

      verified_then_cancelled =
        held_seat(slot, "verified@example.com", DateTime.add(now, -26, :hour),
          email_verified_at: DateTime.add(now, -26, :hour),
          cancelled_at: DateTime.add(now, -25, :hour)
        )

      still_held = held_seat(slot, "held@example.com", DateTime.add(now, -25, :hour))

      assert {1, nil} = EmailVerification.prune_unverified()

      refute Repo.get(ParticipantSchema, lapsed.id)

      for seat <- [visible, recent, verified_then_cancelled, still_held] do
        assert Repo.get(ParticipantSchema, seat.id), "#{seat.email} should have been kept"
      end

      assert Repo.get(MeetingSchema, slot.id)
    end
  end

  defp assert_nothing_started do
    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: VideoRoomWorker)
    assert all_enqueued(worker: EmailWorker) == []
    refute_enqueued(worker: WebhookWorker)
  end

  # A group slot for the context's type at its start time, with no seats. A
  # held slot carries a verification deadline, as one booked through the gate
  # does, which is what keeps it from the organiser.
  defp slot(ctx, status, attrs \\ []) do
    defaults = [
      status: status,
      verification_deadline_at: slot_deadline(status),
      organizer_user_id: ctx.user.id,
      organizer_email: ctx.user.email,
      meeting_type_id: ctx.type.id,
      start_time: ctx.start_time,
      end_time: DateTime.add(ctx.start_time, 1, :hour),
      duration: 60,
      capacity: 3,
      video_integration_id: nil
    ]

    insert(:group_meeting, Keyword.merge(defaults, attrs))
  end

  defp slot_deadline(:awaiting_verification),
    do: DateTime.add(DateTime.utc_now(:second), 30, :minute)

  defp slot_deadline(_status), do: nil

  defp held_seat(slot, email, deadline \\ nil, attrs \\ []) do
    deadline = deadline || DateTime.add(DateTime.utc_now(:second), 30, :minute)

    insert(
      :participant,
      [meeting: slot, email: email, verification_deadline_at: deadline] ++ attrs
    )
  end

  defp visible_seat(slot, email, attrs \\ []),
    do: insert(:participant, [meeting: slot, email: email] ++ attrs)

  defp seat_confirmation_args(slot, seat) do
    %{
      "action" => "send_seat_confirmation_emails",
      "meeting_id" => slot.id,
      "participant_id" => seat.id
    }
  end

  defp calendar_actions(slot) do
    [worker: CalendarEventWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["meeting_id"] == slot.id))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(& &1.args["action"])
  end

  defp reload(%MeetingSchema{id: id}), do: Repo.get!(MeetingSchema, id)
  defp reload(%ParticipantSchema{id: id}), do: Repo.get!(ParticipantSchema, id)
end
