defmodule Tymeslot.Factory.MeetingPaymentFactories do
  @moduledoc """
  The payment factories (Stripe Connect accounts, booking payments and
  their refunds, seat holds), mixed into `Tymeslot.Factory` with `use`. Call them through
  `Tymeslot.Factory`: `insert(:booking_payment, meeting: meeting)`. Seat holds
  live here because they are payment state: an unpaid booker's claim on seats.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.MeetingPayments.BookingPaymentSchema
      alias Tymeslot.MeetingPayments.ConnectAccountSchema
      alias Tymeslot.MeetingPayments.RefundSchema
      alias Tymeslot.Meetings.SeatHoldSchema

      @doc """
      A live hold on one seat of a group meeting; pass `meeting`. Its
      `start_time` is the meeting's unless given.
      """
      @spec seat_hold_factory(map()) :: SeatHoldSchema.t()
      def seat_hold_factory(attrs) do
        meeting = Map.get_lazy(attrs, :meeting, fn -> build(:group_meeting) end)

        hold = %SeatHoldSchema{
          meeting: meeting,
          start_time: meeting.start_time,
          seats: 1,
          # A hold outlives its 30-minute checkout by a grace
          # (`CheckoutSessions.hold_expiry_seconds/0`).
          expires_at: DateTime.add(DateTime.utc_now(:second), 35, :minute),
          name: sequence(:seat_hold_name, &"Holder #{&1}"),
          email: sequence(:seat_hold_email, &"holder#{&1}@test.com"),
          timezone: "Europe/Zurich"
        }

        hold |> merge_attributes(attrs) |> evaluate_lazy_attributes()
      end

      @spec connect_account_factory() :: Tymeslot.MeetingPayments.ConnectAccountSchema.t()
      def connect_account_factory do
        %ConnectAccountSchema{
          stripe_account_id: sequence(:stripe_account_id, &"acct_#{&1}"),
          country: "ch",
          default_currency: "chf",
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          status: :active,
          user: build(:user)
        }
      end

      # A payment given only its refunded total had every refund but a lost
      # dispute's part made at Stripe, as the refund handlers record it; give
      # `stripe_refunded_cents` to set the refunds apart.
      @spec booking_payment_factory(map()) :: BookingPaymentSchema.t()
      def booking_payment_factory(attrs) do
        %BookingPaymentSchema{
          stripe_account_id: sequence(:bp_stripe_account_id, &"acct_#{&1}"),
          host_user_id: sequence(:bp_host_user_id, & &1),
          host_email: sequence(:bp_host_email, &"host#{&1}@test.com"),
          host_name: "Host",
          attendee_email: sequence(:bp_attendee_email, &"attendee#{&1}@test.com"),
          attendee_name: "Attendee",
          meeting_type_name: "Consult",
          booking_theme_id: "1",
          amount_cents: 5000,
          currency: "eur",
          application_fee_cents: 25,
          status: :pending,
          refunded_amount_cents: 0,
          pending_refund_cents: 0
        }
        |> merge_attributes(attrs)
        |> evaluate_lazy_attributes()
        |> derive_stripe_refunded(attrs)
      end

      # A settled charge, which is what the refund flow acts on.
      @spec paid_booking_payment_factory(map()) :: BookingPaymentSchema.t()
      def paid_booking_payment_factory(attrs) do
        %{
          stripe_charge_id: sequence(:bp_stripe_charge_id, &"ch_#{&1}"),
          status: :paid,
          paid_at: DateTime.utc_now(:second)
        }
        |> Map.merge(attrs)
        |> booking_payment_factory()
      end

      defp derive_stripe_refunded(payment, %{stripe_refunded_cents: _given}), do: payment

      defp derive_stripe_refunded(payment, _attrs),
        do: %{
          payment
          | stripe_refunded_cents:
              max(payment.refunded_amount_cents - payment.disputed_lost_cents, 0)
        }

      # A refund recorded but not yet made; give it a `booking_payment`.
      @spec booking_payment_refund_factory() :: RefundSchema.t()
      def booking_payment_refund_factory do
        %RefundSchema{amount_cents: 1000, source: :host, status: :pending, attempt: 0}
      end
    end
  end
end
