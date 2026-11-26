defmodule Tymeslot.Bookings.VerifiedSeatOnPaidSlotIntegrationTest do
  @moduledoc """
  A seat awaiting email verification on a slot a paid seat hold created
  (`:awaiting_payment`): its host made the type free and asked for email
  verification while a booker was still paying. The seat does not count, so
  it holds the slot for verification rather than confirming it; verifying it
  brings the slot to life with its first-seat effects, the hold lapsing
  meanwhile announces nothing, and the seat lapsing while the hold is still
  open hands the slot back to the hold rather than voiding it.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.CreateGroup
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")

    # Free and gated now; the slot below was created while it was paid.
    type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        max_participants: 3,
        requires_email_verification: true
      )

    insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])

    date = Date.add(Date.utc_today(), 2)

    start_time =
      date |> DateTime.new!(~T[14:00:00], "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

    slot =
      insert(:group_meeting,
        status: :awaiting_payment,
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type_id: type.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour),
        duration: 60,
        capacity: 3,
        video_integration_id: nil,
        reminders: [%{"value" => 1, "unit" => "hours"}]
      )

    hold = insert(:seat_hold, meeting: slot, email: "payer@example.com")

    params = %{
      date: date,
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: type.id
    }

    {:ok, %MeetingSchema{id: slot_id}} =
      Create.execute(params, %{
        "name" => "Gated",
        "email" => "gated@example.com",
        "message" => ""
      })

    seat = Repo.get_by!(ParticipantSchema, meeting_id: slot.id, email: "gated@example.com")

    %{slot: slot, slot_id: slot_id, hold: hold, seat: seat}
  end

  test "the gated seat holds the slot for verification and starts nothing for it", ctx do
    assert ctx.slot_id == ctx.slot.id
    assert ParticipantSchema.unverified?(ctx.seat)

    assert %{status: :awaiting_verification, verification_deadline_at: deadline} =
             reload(ctx.slot)

    assert deadline == ctx.seat.verification_deadline_at

    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: WebhookWorker)

    assert ["send_seat_email_verification"] = email_actions()
  end

  test "verifying the seat brings the slot to life with its first-seat effects", ctx do
    assert {:ok, :verified, %MeetingSchema{status: :confirmed}} =
             EmailVerification.verify_seat(ctx.seat)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "create", "meeting_id" => ctx.slot.id}
    )

    assert "send_reminder_emails" in email_actions()
    assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.created"})
  end

  test "the hold lapsing leaves the slot held for the seat, announcing nothing", ctx do
    release_hold(ctx.hold)

    assert reload(ctx.slot).status == :awaiting_verification
    assert email_actions() == ["send_seat_email_verification"]
    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: WebhookWorker)

    assert {:ok, :verified, %MeetingSchema{status: :confirmed}} =
             EmailVerification.verify_seat(ctx.seat)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "create", "meeting_id" => ctx.slot.id}
    )
  end

  describe "the seat lapsing while the hold is open" do
    setup ctx do
      assert {:ok, _expired} = EmailVerification.expire_seat(ctx.seat)
      :ok
    end

    test "returns the slot to awaiting payment, still held by the hold", ctx do
      assert %{status: :awaiting_payment, verification_deadline_at: nil, cancelled_at: nil} =
               reload(ctx.slot)

      assert SeatHolds.get(ctx.hold.id).status == :held
    end

    test "lets the hold's payment confirm the slot as its first seat", ctx do
      assert {:ok, {:ok, booking}} =
               Repo.transaction(fn -> CreateGroup.complete_paid_hold(ctx.hold.id) end)

      assert booking.meeting.id == ctx.slot.id
      assert booking.created_meeting?
      assert reload(ctx.slot).status == :confirmed

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => ctx.slot.id}
      )
    end

    test "expires the slot once the hold lapses too", ctx do
      release_hold(ctx.hold)

      assert reload(ctx.slot).status == :expired
    end
  end

  defp release_hold(hold) do
    {:ok, released} =
      Repo.transaction(fn -> elem(SeatRelease.release_hold(hold, :expired), 1) end)

    :ok = SeatRelease.announce_released(released)
  end

  defp email_actions do
    [worker: EmailWorker] |> all_enqueued() |> Enum.map(& &1.args["action"]) |> Enum.sort()
  end

  defp reload(%MeetingSchema{id: id}), do: Repo.get!(MeetingSchema, id)
end
