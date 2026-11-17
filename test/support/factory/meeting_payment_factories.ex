defmodule Tymeslot.Factory.MeetingPaymentFactories do
  @moduledoc """
  The payment factories (Stripe Connect accounts, booking payments, seat
  holds), mixed into `Tymeslot.Factory` with `use`. Call them through
  `Tymeslot.Factory`: `insert(:booking_payment, meeting: meeting)`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.MeetingPayments.BookingPaymentSchema
      alias Tymeslot.MeetingPayments.ConnectAccountSchema
      alias Tymeslot.Meetings.SeatHoldSchema

      @doc "A live hold on one seat of a group meeting; pass `meeting`."
      @spec seat_hold_factory() :: SeatHoldSchema.t()
      def seat_hold_factory do
        %SeatHoldSchema{
          meeting: build(:group_meeting),
          start_time: DateTime.utc_now(:second),
          seats: 1,
          expires_at: DateTime.add(DateTime.utc_now(:second), 30, :minute),
          name: sequence(:seat_hold_name, &"Holder #{&1}"),
          email: sequence(:seat_hold_email, &"holder#{&1}@test.com"),
          timezone: "Europe/Zurich"
        }
      end

      @spec connect_account_factory() :: ConnectAccountSchema.t()
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

      @spec booking_payment_factory() :: BookingPaymentSchema.t()
      def booking_payment_factory do
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
          refunded_amount_cents: 0
        }
      end

      # A settled charge, which is what the refund flow acts on.
      @spec paid_booking_payment_factory() :: BookingPaymentSchema.t()
      def paid_booking_payment_factory do
        struct!(booking_payment_factory(),
          stripe_charge_id: sequence(:bp_stripe_charge_id, &"ch_#{&1}"),
          status: :paid,
          paid_at: DateTime.utc_now(:second)
        )
      end
    end
  end
end
