defmodule Tymeslot.Migrations.MakeSeatPaymentParticipantUniqueTest do
  @moduledoc """
  Value-correctness regression for
  `20261118092242_make_seat_payment_participant_unique`, which makes
  `booking_payments_participant_id_index` unique over seat payments.

  The decisive properties are that duplicates already on a participant are
  settled in favour of the earliest seat payment, which keeps the link, and
  that the index the migration leaves refuses a second one.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :payments

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_118_092_242

  defp seat_payment(meeting, participant, inserted_at) do
    insert(:paid_booking_payment,
      meeting_id: meeting.id,
      participant_id: participant && participant.id,
      seat_payment: true,
      inserted_at: inserted_at
    )
  end

  defp participant_of(payment), do: Repo.get!(BookingPaymentSchema, payment.id).participant_id

  test "the earliest seat payment keeps a participant two of them name" do
    MigrationRunner.down!(@version)

    meeting = insert(:group_meeting)
    participant = insert(:participant, meeting: meeting)
    later = seat_payment(meeting, participant, ~U[2026-11-02 10:00:00Z])
    earliest = seat_payment(meeting, participant, ~U[2026-11-01 10:00:00Z])

    untouched =
      seat_payment(meeting, insert(:participant, meeting: meeting), ~U[2026-11-03 10:00:00Z])

    MigrationRunner.up!(@version)

    assert participant_of(earliest) == participant.id
    assert participant_of(later) == nil
    assert participant_of(untouched) == untouched.participant_id
    assert Repo.get!(BookingPaymentSchema, later.id).meeting_id == meeting.id
  end

  test "a plain payment naming a seat's participant is left alone" do
    MigrationRunner.down!(@version)

    meeting = insert(:group_meeting)
    participant = insert(:participant, meeting: meeting)
    seat = seat_payment(meeting, participant, ~U[2026-11-02 10:00:00Z])

    plain =
      insert(:paid_booking_payment,
        meeting_id: insert(:meeting).id,
        participant_id: participant.id,
        inserted_at: ~U[2026-11-01 10:00:00Z]
      )

    MigrationRunner.up!(@version)

    assert participant_of(seat) == participant.id
    assert participant_of(plain) == participant.id
  end

  test "after it, a second seat payment on a participant is refused" do
    meeting = insert(:group_meeting)
    participant = insert(:participant, meeting: meeting)
    seat_payment(meeting, participant, ~U[2026-11-01 10:00:00Z])

    MigrationRunner.rerun!(@version)

    assert_raise Ecto.ConstraintError, ~r/booking_payments_participant_id_index/, fn ->
      seat_payment(meeting, participant, ~U[2026-11-02 10:00:00Z])
    end
  end

  test "down puts back an index that allows duplicates" do
    meeting = insert(:group_meeting)
    participant = insert(:participant, meeting: meeting)
    seat_payment(meeting, participant, ~U[2026-11-01 10:00:00Z])

    MigrationRunner.down!(@version)

    assert %BookingPaymentSchema{} = seat_payment(meeting, participant, ~U[2026-11-02 10:00:00Z])
  end
end
