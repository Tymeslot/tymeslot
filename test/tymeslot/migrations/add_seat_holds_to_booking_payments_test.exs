defmodule Tymeslot.Migrations.AddSeatHoldsToBookingPaymentsTest do
  @moduledoc """
  Verifies `20261117171055_add_seat_holds_to_booking_payments`: several seat
  payments may share a meeting while a plain payment still may not, a hold
  takes one payment, and existing rows read as one non-seat seat.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_117_171_055

  defp seat_payment(meeting, hold, attrs \\ []) do
    insert(
      :booking_payment,
      Keyword.merge([meeting: meeting, seat_hold: hold, seat_payment: true], attrs)
    )
  end

  test "two seat payments may share a meeting" do
    meeting = insert(:group_meeting)
    [h1, h2] = insert_pair(:seat_hold, meeting: meeting)

    p1 = seat_payment(meeting, h1)
    p2 = seat_payment(meeting, h2)

    assert Repo.reload!(p1).meeting_id == meeting.id
    assert Repo.reload!(p2).meeting_id == meeting.id
  end

  test "a meeting still takes one non-seat payment" do
    meeting = insert(:meeting)
    insert(:booking_payment, meeting: meeting)

    assert_raise Ecto.ConstraintError, ~r/booking_payments_meeting_id_index/, fn ->
      insert(:booking_payment, meeting: meeting)
    end
  end

  test "two seat payments may share a meeting after their holds are deleted" do
    meeting = insert(:group_meeting)
    [h1, h2] = insert_pair(:seat_hold, meeting: meeting)
    p1 = seat_payment(meeting, h1)
    p2 = seat_payment(meeting, h2)

    Repo.query!("DELETE FROM seat_holds WHERE meeting_id = $1", [UUID.dump!(meeting.id)])

    assert [nil, nil] = Enum.map([p1, p2], &Repo.reload!(&1).seat_hold_id)
    assert Enum.map([p1, p2], &Repo.reload!(&1).meeting_id) == [meeting.id, meeting.id]
  end

  test "a hold takes one payment" do
    meeting = insert(:group_meeting)
    hold = insert(:seat_hold, meeting: meeting)
    seat_payment(meeting, hold)

    assert_raise Ecto.ConstraintError, ~r/booking_payments_seat_hold_id_index/, fn ->
      seat_payment(meeting, hold)
    end
  end

  test "existing payments read as one seat" do
    MigrationRunner.down!(@version)

    id = UUID.generate()
    now = DateTime.utc_now(:second)

    Repo.query!(
      """
      INSERT INTO booking_payments
        (id, stripe_account_id, host_user_id, host_email, meeting_type_name,
         amount_cents, currency, application_fee_cents, status, refunded_amount_cents,
         inserted_at, updated_at)
      VALUES ($1, 'acct_old', 1, 'h@x.test', 'Consult', 5000, 'eur', 25, 'pending', 0, $2, $2)
      """,
      [UUID.dump!(id), now]
    )

    MigrationRunner.up!(@version)

    assert %{rows: [[1, false]]} =
             Repo.query!("SELECT seats, seat_payment FROM booking_payments WHERE id = $1", [
               UUID.dump!(id)
             ])
  end

  test "seats below one is refused" do
    now = DateTime.utc_now(:second)

    assert_raise Postgrex.Error, ~r/booking_payments_seats_positive/, fn ->
      Repo.query!(
        """
        INSERT INTO booking_payments
          (id, stripe_account_id, host_user_id, host_email, meeting_type_name,
           amount_cents, currency, application_fee_cents, status, refunded_amount_cents,
           seats, inserted_at, updated_at)
        VALUES ($1, 'acct_x', 1, 'h@x.test', 'Consult', 5000, 'eur', 25, 'pending', 0, 0, $2, $2)
        """,
        [UUID.dump!(UUID.generate()), now]
      )
    end
  end
end
