defmodule Tymeslot.MeetingPayments.BookingPaymentSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentSchema

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

      cs = BookingPaymentSchema.update_changeset(payment, %{status: "paid"})
      assert cs.valid?

      {:ok, updated} = Repo.update(cs)
      assert updated.status == "paid"
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
end
