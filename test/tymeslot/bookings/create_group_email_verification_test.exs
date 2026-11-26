defmodule Tymeslot.Bookings.CreateGroupEmailVerificationTest do
  @moduledoc """
  Booking a seat on a group type that requires email verification. The seat
  holds its place but starts nothing beyond its own verification email and
  expiry job: the organiser and the other attendees learn nothing of it until
  it is verified.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.Repo
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

  test "the first gated seat creates a held, hidden slot", ctx do
    assert {:ok, %MeetingSchema{id: slot_id}} = book(ctx, "first@example.com")

    slot = Repo.get!(MeetingSchema, slot_id)
    assert slot.status == :awaiting_verification
    assert %DateTime{} = slot.verification_deadline_at

    assert [seat] = seats(slot)
    assert ParticipantSchema.unverified?(seat)
    assert seat.verification_deadline_at == slot.verification_deadline_at

    assert [%{args: %{"action" => "send_seat_email_verification"} = args}] =
             all_enqueued(worker: EmailWorker)

    assert args["meeting_id"] == slot.id
    assert args["participant_id"] == seat.id

    assert_enqueued(
      worker: EmailVerificationExpiryWorker,
      args: %{"participant_id" => seat.id},
      scheduled_at: seat.verification_deadline_at
    )

    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: VideoRoomWorker)
    refute_enqueued(worker: WebhookWorker)

    assert Meetings.list_upcoming_meetings_for_organizer(ctx.user.id) == []

    assert Meetings.list_meetings_in_range_for_organizer(
             ctx.user.id,
             DateTime.add(ctx.start_time, -1, :day),
             DateTime.add(ctx.start_time, 1, :day)
           ) == []
  end

  test "a gated seat on a live slot is hidden from the others", ctx do
    slot = live_slot(ctx)
    first = insert(:participant, meeting: slot, email: "first@example.com")
    recipients_before = Recipient.for_meeting(slot)

    assert {:ok, %{id: slot_id}} = book(ctx, "second@example.com")
    assert slot_id == slot.id
    assert Repo.get!(MeetingSchema, slot.id).status == :confirmed

    assert [%{args: %{"action" => "send_seat_email_verification"} = args}] =
             all_enqueued(worker: EmailWorker)

    refute args["participant_id"] == first.id

    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: WebhookWorker)
    assert Recipient.for_meeting(slot) == recipients_before
  end

  test "a held seat fills the slot for the public", ctx do
    {:ok, _type} = set_type(ctx.type, max_participants: 2)

    assert {:ok, %{id: slot_id}} = book(ctx, "first@example.com")
    assert {:ok, %{id: ^slot_id}} = book(ctx, "second@example.com")

    assert {:error, :slot_taken} = book(ctx, "third@example.com")

    assert [_first, _second] = held = seats(%{id: slot_id})
    assert Enum.reject(held, &ParticipantSchema.unverified?/1) == []
  end

  test "an ungated seat on a held slot activates it", ctx do
    assert {:ok, %{id: slot_id}} = book(ctx, "first@example.com")
    assert [held] = seats(%{id: slot_id})

    {:ok, _type} = set_type(ctx.type, requires_email_verification: false)

    assert {:ok, %{id: ^slot_id}} = book(ctx, "second@example.com")

    assert %{status: :confirmed, email_verified_at: %DateTime{}} =
             Repo.get!(MeetingSchema, slot_id)

    assert calendar_actions(slot_id) == ["create"]

    assert [_reminders] =
             all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})

    assert [_created] = all_enqueued(worker: WebhookWorker)

    assert ParticipantSchema.unverified?(Repo.get!(ParticipantSchema, held.id))

    assert [%{email: "second@example.com"}] =
             Recipient.for_meeting(Repo.get!(MeetingSchema, slot_id))
  end

  test "a lapsed held slot is kept a day from its last seat's deadline, not its first", ctx do
    t0 = DateTime.utc_now(:second)
    freeze_clock(t0)
    assert {:ok, %MeetingSchema{id: slot_id}} = book(ctx, "first@example.com")

    freeze_clock(DateTime.add(t0, 10, :minute))
    assert {:ok, %MeetingSchema{id: ^slot_id}} = book(ctx, "second@example.com")

    [first, second] =
      %{id: slot_id} |> seats() |> Enum.sort_by(& &1.verification_deadline_at)

    assert DateTime.after?(second.verification_deadline_at, first.verification_deadline_at)

    assert Repo.get!(MeetingSchema, slot_id).verification_deadline_at ==
             second.verification_deadline_at

    freeze_clock(DateTime.add(second.verification_deadline_at, 1, :minute))
    assert {:ok, _first_expired} = EmailVerification.expire_seat(first)
    assert {:ok, _second_expired} = EmailVerification.expire_seat(second)
    assert Repo.get!(MeetingSchema, slot_id).status == :expired

    freeze_clock(DateTime.add(first.verification_deadline_at, 24 * 60 + 5, :minute))
    EmailVerification.prune_unverified()
    assert Repo.get(MeetingSchema, slot_id)

    freeze_clock(DateTime.add(second.verification_deadline_at, 24 * 60 + 1, :minute))
    EmailVerification.prune_unverified()
    refute Repo.get(MeetingSchema, slot_id)
  end

  defp book(ctx, email) do
    Create.execute(ctx.params, %{"name" => "Booker", "email" => email, "message" => ""})
  end

  defp live_slot(ctx) do
    insert(:group_meeting,
      status: :confirmed,
      organizer_user_id: ctx.user.id,
      organizer_email: ctx.user.email,
      meeting_type_id: ctx.type.id,
      start_time: ctx.start_time,
      end_time: DateTime.add(ctx.start_time, 1, :hour),
      duration: 60,
      capacity: 3,
      video_integration_id: nil
    )
  end

  # Bypasses the form's rules, which (until group verification is offered
  # in the editor) refuse a gated group type.
  defp set_type(type, changes), do: type |> change(changes) |> Repo.update()

  defp seats(%{id: slot_id}) do
    ParticipantSchema
    |> where([p], p.meeting_id == ^slot_id)
    |> Repo.all()
  end

  defp calendar_actions(slot_id) do
    [worker: CalendarEventWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["meeting_id"] == slot_id))
    |> Enum.map(& &1.args["action"])
  end
end
