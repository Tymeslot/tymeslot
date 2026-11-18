defmodule Tymeslot.MeetingPayments.BookingPaymentSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

  @valid_attrs %{
    stripe_account_id: "acct_TEST",
    host_user_id: 1,
    host_email: "host@example.com",
    attendee_email: "attendee@example.com",
    meeting_type_name: "Consult",
    amount_cents: 5000,
    currency: "eur",
    application_fee_cents: 25
  }

  describe "create_changeset/1" do
    test "is valid with required attrs" do
      cs = BookingPaymentSchema.create_changeset(@valid_attrs)
      assert cs.valid?
    end

    test "rejects amount_cents == 0" do
      cs = BookingPaymentSchema.create_changeset(%{@valid_attrs | amount_cents: 0})
      refute cs.valid?
      assert "must be greater than 0" in errors_on(cs).amount_cents
    end

    test "rejects negative refunded" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :refunded_amount_cents, -1))

      refute cs.valid?
      assert "must be non-negative" in errors_on(cs).refunded_amount_cents
    end

    test "rejects refunded greater than amount" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :refunded_amount_cents, 6000))

      refute cs.valid?
      assert "cannot exceed amount_cents" in errors_on(cs).refunded_amount_cents
    end

    test "rejects unknown status" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :status, "weird"))

      refute cs.valid?
      assert "is invalid" in errors_on(cs).status
    end

    test "rejects missing host_email" do
      cs =
        BookingPaymentSchema.create_changeset(Map.delete(@valid_attrs, :host_email))

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).host_email
    end

    test "rejects negative application_fee_cents" do
      cs =
        BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :application_fee_cents, -1))

      refute cs.valid?
      assert "must be greater than or equal to 0" in errors_on(cs).application_fee_cents
    end
  end

  describe "update_changeset/2" do
    test "transitions status from pending to paid" do
      {:ok, payment} =
        @valid_attrs
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      cs = BookingPaymentSchema.update_changeset(payment, %{status: :paid})
      assert cs.valid?

      {:ok, updated} = Repo.update(cs)
      assert updated.status == :paid
    end

    test "DB CHECK rejects refunded > amount" do
      {:ok, payment} =
        @valid_attrs
        |> BookingPaymentSchema.create_changeset()
        |> Repo.insert()

      assert_raise Postgrex.Error, ~r/refunded_amount_within_bounds/, fn ->
        Repo.query!(
          "UPDATE booking_payments SET refunded_amount_cents = $1 WHERE id = $2",
          [99_999, UUID.dump!(payment.id)]
        )
      end
    end
  end

  describe "seat payments" do
    defp insert_seat_payment(meeting, hold, extra \\ %{}) do
      %{@valid_attrs | amount_cents: 5000}
      |> Map.merge(%{meeting_id: meeting.id, seat_hold_id: hold.id})
      |> Map.merge(extra)
      |> BookingPaymentSchema.create_changeset()
      |> Repo.insert()
    end

    test "two seat payments may share a meeting" do
      meeting = insert(:group_meeting)
      [h1, h2] = insert_pair(:seat_hold, meeting: meeting)

      assert {:ok, p1} = insert_seat_payment(meeting, h1)
      assert {:ok, p2} = insert_seat_payment(meeting, h2)
      assert Enum.map([p1, p2], &Repo.reload!(&1).meeting_id) == [meeting.id, meeting.id]
    end

    test "a hold's payment is marked as a seat payment, whatever the caller passes" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)

      assert {:ok, payment} = insert_seat_payment(meeting, hold, %{seat_payment: false})
      assert payment.seat_payment

      plain = BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :seat_payment, true))
      refute Changeset.get_field(plain, :seat_payment)
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
      {:ok, p1} = insert_seat_payment(meeting, h1)
      {:ok, p2} = insert_seat_payment(meeting, h2)

      Repo.query!("DELETE FROM seat_holds WHERE meeting_id = $1", [UUID.dump!(meeting.id)])

      assert [nil, nil] = Enum.map([p1, p2], &Repo.reload!(&1).seat_hold_id)
      assert Enum.map([p1, p2], &Repo.reload!(&1).meeting_id) == [meeting.id, meeting.id]
    end

    test "a hold takes one payment" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)
      {:ok, _payment} = insert_seat_payment(meeting, hold)

      assert {:error, changeset} = insert_seat_payment(meeting, hold)
      assert %{seat_hold_id: [_message]} = errors_on(changeset)
    end

    test "seats below one is refused" do
      cs = BookingPaymentSchema.create_changeset(Map.put(@valid_attrs, :seats, 0))
      assert {:error, changeset} = Repo.insert(cs)
      assert %{seats: [_message]} = errors_on(changeset)
    end

    test "move_seat_changeset/2 moves a seat payment to another meeting and participant" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)
      {:ok, payment} = insert_seat_payment(meeting, hold)
      other = insert(:group_meeting)
      participant = insert(:participant, meeting: other)

      {:ok, moved} =
        payment
        |> BookingPaymentSchema.move_seat_changeset(%{
          meeting_id: other.id,
          participant_id: participant.id
        })
        |> Repo.update()

      reloaded = Repo.reload!(moved)
      assert reloaded.meeting_id == other.id
      assert reloaded.participant_id == participant.id
    end

    test "move_seat_changeset/2 refuses a plain payment and missing targets" do
      plain = insert(:booking_payment, meeting: insert(:meeting))
      other = insert(:group_meeting)
      participant = insert(:participant, meeting: other)

      cs =
        BookingPaymentSchema.move_seat_changeset(plain, %{
          meeting_id: other.id,
          participant_id: participant.id
        })

      assert %{seat_payment: [_message]} = errors_on(cs)

      seat = insert(:booking_payment, seat_payment: true, meeting: other)
      cs = BookingPaymentSchema.move_seat_changeset(seat, %{meeting_id: nil, participant_id: nil})
      assert %{meeting_id: [_meeting_error], participant_id: [_participant_error]} = errors_on(cs)
    end

    test "move_seat_changeset/2 reports an unknown meeting as a changeset error" do
      seat = insert(:booking_payment, seat_payment: true, meeting: insert(:group_meeting))
      participant = insert(:participant)

      assert {:error, cs} =
               seat
               |> BookingPaymentSchema.move_seat_changeset(%{
                 meeting_id: UUID.generate(),
                 participant_id: participant.id
               })
               |> Repo.update()

      assert %{meeting_id: [_message]} = errors_on(cs)
    end

    test "convert_changeset/2 links the participant and refuses a missing or unknown one" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)
      {:ok, payment} = insert_seat_payment(meeting, hold)
      participant = insert(:participant, meeting: meeting)

      {:ok, converted} =
        payment
        |> BookingPaymentSchema.convert_changeset(%{participant_id: participant.id})
        |> Repo.update()

      assert Repo.reload!(converted).participant_id == participant.id

      assert %{participant_id: [_message]} =
               errors_on(BookingPaymentSchema.convert_changeset(payment, %{participant_id: nil}))

      assert {:error, cs} =
               payment
               |> BookingPaymentSchema.convert_changeset(%{participant_id: UUID.generate()})
               |> Repo.update()

      assert %{participant_id: [_message]} = errors_on(cs)
    end

    test "convert_changeset/2 refuses a participant another seat payment already paid for" do
      meeting = insert(:group_meeting)
      [h1, h2] = insert_pair(:seat_hold, meeting: meeting)
      participant = insert(:participant, meeting: meeting)
      {:ok, _paid} = insert_seat_payment(meeting, h1, %{participant_id: participant.id})
      {:ok, other} = insert_seat_payment(meeting, h2)

      assert {:error, cs} =
               other
               |> BookingPaymentSchema.convert_changeset(%{participant_id: participant.id})
               |> Repo.update()

      assert %{participant_id: ["has already been taken"]} = errors_on(cs)
    end

    test "move_seat_changeset/2 refuses a participant another seat payment already paid for" do
      meeting = insert(:group_meeting)
      [h1, h2] = insert_pair(:seat_hold, meeting: meeting)
      other = insert(:group_meeting)
      participant = insert(:participant, meeting: other)
      {:ok, _paid} = insert_seat_payment(meeting, h1, %{participant_id: participant.id})
      {:ok, moving} = insert_seat_payment(meeting, h2)

      assert {:error, cs} =
               moving
               |> BookingPaymentSchema.move_seat_changeset(%{
                 meeting_id: other.id,
                 participant_id: participant.id
               })
               |> Repo.update()

      assert %{participant_id: ["has already been taken"]} = errors_on(cs)
    end

    test "a plain payment may share a participant id with a seat payment" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)
      participant = insert(:participant, meeting: meeting)
      {:ok, _seat} = insert_seat_payment(meeting, hold, %{participant_id: participant.id})

      assert {:ok, _plain} =
               @valid_attrs
               |> Map.merge(%{participant_id: participant.id, meeting_id: insert(:meeting).id})
               |> BookingPaymentSchema.create_changeset()
               |> Repo.insert()
    end
  end
end
