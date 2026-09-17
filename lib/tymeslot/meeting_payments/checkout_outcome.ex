defmodule Tymeslot.MeetingPayments.CheckoutOutcome do
  @moduledoc """
  What an attendee returning from Stripe Checkout should be told about their
  booking, derived from the payment and meeting rows alone.

  The return page used to work this out for itself, and got it wrong in ways
  an attendee could see: every paid booking that was not declined, expired or
  held read as confirmed, including one the attendee had withdrawn or the host
  had cancelled, and a payment that failed left the page spinning forever. The
  rule lives here so the page renders an answer instead of deriving one.

  Two facts carry the classification, and neither is `payment.status`:

    * `payment.paid_at` proves this checkout's payment cycle completed. The
      status cannot, because refunding a released request flips it to
      `"refunded"` while the booking's story is still "paid, then declined".
    * The meeting's own status and gate fields say what became of the booking
      once paid. `Approval.declined?/1` is the only proof of a decline:
      `approval_resolved_at` is stamped by an approval as well.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState

  @type t ::
          :processing
          | :failed
          | :awaiting_approval
          | :declined
          | :expired
          | :confirmed
          | :cancelled

  # A booking in one of these is on, whatever else happened to it since.
  @live_statuses ["confirmed", "completed", "reschedule_requested"]

  # The booking has not caught up with a payment that cleared yet. The webhook
  # writes both rows in one transaction, so this is a moment, not a state.
  @pre_payment_statuses ["pending", "awaiting_payment"]

  # An unpaid checkout whose booking is gone will never complete.
  @ended_statuses ["expired", "cancelled"]

  @doc """
  Classifies a checkout for the attendee. `nil` for either row means there is
  nothing to judge yet, which reads as `:processing`.
  """
  @spec classify(BookingPaymentSchema.t() | nil, MeetingSchema.t() | nil) :: t()
  def classify(nil, _meeting), do: :processing
  def classify(_payment, nil), do: :processing

  def classify(%{paid_at: nil, status: "failed"}, _meeting), do: :failed
  def classify(%{paid_at: nil}, %{status: status}) when status in @ended_statuses, do: :failed
  def classify(%{paid_at: nil}, _meeting), do: :processing

  def classify(_paid, %{status: "expired", approval_resolved_at: %DateTime{}}), do: :expired

  def classify(_paid, meeting) do
    cond do
      Approval.declined?(meeting) -> :declined
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      true -> booking_outcome(meeting.status)
    end
  end

  defp booking_outcome(status) when status in @live_statuses, do: :confirmed
  defp booking_outcome(status) when status in @pre_payment_statuses, do: :processing
  defp booking_outcome(_released), do: :cancelled
end
