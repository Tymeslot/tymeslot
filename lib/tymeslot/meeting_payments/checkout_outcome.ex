defmodule Tymeslot.MeetingPayments.CheckoutOutcome do
  @moduledoc """
  What an attendee returning from Stripe Checkout should be told about their
  booking, derived from the payment and meeting rows alone.

  The rule lives here so the return page renders an answer instead of deriving
  one. A paid booking is not confirmed merely because it was not declined,
  expired or held: the attendee may have withdrawn it or the host cancelled it,
  and a failed payment is reported as failed rather than left pending.

  Two facts carry the classification, and neither is `payment.status`:

    * `payment.paid_at` proves this checkout's payment cycle completed. The
      status cannot, because refunding a released request flips it to
      `:refunded` while the booking's story is still "paid, then declined".
    * The meeting's own status and gate fields say what became of the booking
      once paid. `Approval.declined?/1` is the only proof of a decline:
      `approval_resolved_at` is stamped by an approval as well.

  A held group seat is classified by its hold instead (`classify_seat/2`):
  the group meeting is shared, so its status says how the session stands,
  not whether this booker's seats were paid.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.SeatHoldSchema

  @type t ::
          :processing
          | :failed
          | :awaiting_approval
          | :declined
          | :expired
          | :confirmed
          | :cancelled

  @typedoc """
  The outcomes a held seat's checkout can have: a seat never waits for the
  host's approval, so never `:awaiting_approval` or `:declined`.
  """
  @type seat :: :processing | :failed | :expired | :confirmed | :cancelled

  # A booking in one of these is on, whatever else happened to it since.
  @live_statuses [:confirmed, :completed, :reschedule_requested]

  # The booking has not caught up with a payment that cleared yet. The webhook
  # writes both rows in one transaction, so this is a moment, not a state.
  @pre_payment_statuses [:pending, :awaiting_payment]

  @doc """
  Classifies a checkout for the attendee. `nil` for either row means there is
  nothing to judge yet, which reads as `:processing`.
  """
  @spec classify(BookingPaymentSchema.t() | nil, MeetingSchema.t() | nil) :: t()
  def classify(nil, _meeting), do: :processing
  def classify(_payment, nil), do: :processing

  def classify(%{paid_at: nil, status: :failed}, _meeting), do: :failed
  # An unpaid checkout whose booking was released will never complete.
  def classify(%{paid_at: nil}, %{status: status}) do
    if MeetingState.released_status?(status), do: :failed, else: :processing
  end

  def classify(_paid, %{status: :expired, approval_resolved_at: %DateTime{}}), do: :expired

  def classify(_paid, meeting) do
    cond do
      Approval.declined?(meeting) -> :declined
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      true -> booking_outcome(meeting.status)
    end
  end

  @doc """
  Classifies a held group seat's checkout for its booker, from the hold and
  the payment opened for it, in the vocabulary `classify/2` uses:

    * `:processing` while the hold is held with its payment still pending,
      and when there is no hold to judge;
    * `:confirmed` once the hold became a seat, even one cancelled since;
    * `:cancelled` when the hold was released because its session was
      cancelled;
    * `:failed` when the payment failed, unpaid;
    * `:expired` for any other release: the checkout lapsed or was left, or
      a payment that came too late found no room and is refunded.
  """
  @spec classify_seat(SeatHoldSchema.t() | nil, BookingPaymentSchema.t() | nil) :: seat()
  def classify_seat(nil, _payment), do: :processing
  def classify_seat(%SeatHoldSchema{status: :converted}, _payment), do: :confirmed

  def classify_seat(
        %SeatHoldSchema{status: :released, released_reason: :meeting_cancelled},
        _payment
      ),
      do: :cancelled

  # A payment that completed after its hold was released found no room, and
  # is refunded: the seats lapsed, whatever the release's reason.
  def classify_seat(%SeatHoldSchema{status: :released}, %{paid_at: %DateTime{}}), do: :expired

  def classify_seat(%SeatHoldSchema{status: :released, released_reason: :failed}, _payment),
    do: :failed

  def classify_seat(%SeatHoldSchema{status: :released}, _payment), do: :expired
  def classify_seat(%SeatHoldSchema{status: :held}, %{status: :failed}), do: :failed
  def classify_seat(%SeatHoldSchema{status: :held}, _payment), do: :processing

  defp booking_outcome(status) when status in @live_statuses, do: :confirmed
  defp booking_outcome(status) when status in @pre_payment_statuses, do: :processing
  defp booking_outcome(_released), do: :cancelled
end
