defmodule Tymeslot.MeetingPayments.Checkout do
  @moduledoc """
  Taking a payment for a booking: opening the Stripe Checkout for a meeting,
  a paid series or a held group seat, recognising a guest back from it,
  abandoning it, reading its outcome, and releasing the booking held while
  it was open.

  A public sibling of `Tymeslot.MeetingPayments`, callable from anywhere the
  context is.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.CheckoutOutcome
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.SeatHoldCheckouts
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHoldSchema

  @doc """
  The PubSub topic carrying a meeting's payment status changes. Subscribers
  receive the bare atoms `:paid` and `:expired`.
  """
  @spec payment_topic(String.t()) :: String.t()
  defdelegate payment_topic(meeting_id), to: HeldMeetings, as: :topic

  @doc """
  Releases a booking held for payment, inside the caller's transaction and
  after its payment has been locked or claimed. See
  `Tymeslot.MeetingPayments.HeldMeetings.expire/1`.
  """
  @spec expire_held_meeting(String.t() | nil) ::
          {:ok, :expired, MeetingSchema.t()}
          | {:ok, :unchanged}
          | {:error, Ecto.Changeset.t()}
  defdelegate expire_held_meeting(meeting_id), to: HeldMeetings, as: :expire

  @doc """
  After the transaction that released a held booking has committed, offers
  its slot again and tells the waiting attendee it expired.
  """
  @spec announce_expired(MeetingSchema.t()) :: :ok
  defdelegate announce_expired(meeting), to: HeldMeetings

  @doc """
  Creates a Stripe Checkout Session for an `awaiting_payment` meeting.

  Returns the Stripe-hosted checkout URL and the persisted `booking_payment` row.
  """
  @spec create_checkout_session(MeetingSchema.t()) ::
          {:ok, CheckoutSessions.create_result()} | {:error, term()}
  defdelegate create_checkout_session(meeting),
    to: CheckoutSessions,
    as: :create_session_for_booking

  @doc """
  Opens a Stripe Checkout for a held group seat. See
  `CheckoutSessions.create_session_for_seat_hold/1`.
  """
  @spec create_seat_checkout_session(SeatHoldSchema.t()) ::
          {:ok, CheckoutSessions.create_result()} | {:error, term()}
  defdelegate create_seat_checkout_session(hold),
    to: CheckoutSessions,
    as: :create_session_for_seat_hold

  @doc "How long a seat hold lasts, in seconds: a little longer than its checkout."
  @spec hold_expiry_seconds() :: pos_integer()
  defdelegate hold_expiry_seconds, to: CheckoutSessions

  @doc """
  Fails the pending payment of a seat hold whose checkout could not be
  opened. See `SeatHoldCheckouts.fail_seat_payment/1`.
  """
  @spec fail_seat_payment(String.t()) ::
          {:ok, BookingPaymentSchema.t() | :unchanged} | {:error, Ecto.Changeset.t()}
  defdelegate fail_seat_payment(hold_id), to: SeatHoldCheckouts

  @doc """
  Opens one Stripe Checkout for every session of a paid series, held
  `awaiting_payment`, at the series' unit price times its sessions. See
  `CheckoutSessions.create_session_for_series/1`.
  """
  @spec create_checkout_session_for_series(Tymeslot.BookingSeries.SeriesSchema.t()) ::
          {:ok, CheckoutSessions.create_result()} | {:error, term()}
  defdelegate create_checkout_session_for_series(series),
    to: CheckoutSessions,
    as: :create_session_for_series

  @doc """
  Expires every session of a paid series still awaiting payment, inside
  the caller's transaction or its own. See `HeldMeetings.expire_series/1`.
  """
  @spec expire_held_series(Tymeslot.BookingSeries.SeriesSchema.t() | binary() | nil) ::
          {:ok, :expired, MeetingSchema.t()}
          | {:ok, :unchanged, String.t() | nil}
          | {:error, term()}
  defdelegate expire_held_series(series), to: HeldMeetings, as: :expire_series

  @doc """
  Whether a checkout-cancelled page's `return_token` proves the visitor came
  back from the checkout of the meeting `meeting_id`. See
  `CheckoutSessions.returned_from_checkout?/2`.
  """
  @spec returned_from_checkout?(String.t(), String.t() | nil) :: boolean()
  defdelegate returned_from_checkout?(meeting_id, return_token), to: CheckoutSessions

  @doc "As `returned_from_checkout?/2`, for the checkout of the seat hold `hold_id`."
  @spec returned_from_seat_checkout?(String.t(), String.t() | nil) :: boolean()
  defdelegate returned_from_seat_checkout?(hold_id, return_token), to: CheckoutSessions

  @doc """
  Expires the open Stripe Checkout of a booking its guest has just left, so
  its hold ends now rather than at the checkout's timeout. See
  `CheckoutSessions.abandon_checkout/1`.
  """
  @spec abandon_checkout(String.t()) :: :ok | {:error, term()}
  defdelegate abandon_checkout(meeting_id), to: CheckoutSessions

  @doc """
  Schedules the end of the open Stripe Checkout of a booking being
  cancelled while it awaits payment, inside the cancelling transaction. See
  `CheckoutSessions.schedule_close/1`.
  """
  @spec schedule_checkout_close(MeetingSchema.t()) :: :ok | {:error, term()}
  defdelegate schedule_checkout_close(meeting), to: CheckoutSessions, as: :schedule_close

  @doc "As `abandon_checkout/1`, for the checkout of the seat hold `hold_id`."
  @spec abandon_seat_checkout(String.t()) :: :ok | {:error, term()}
  defdelegate abandon_seat_checkout(hold_id), to: CheckoutSessions

  @doc """
  Once a meeting's cancellation has committed, expires the open checkouts
  of the seat holds it released and tells their bookers. See
  `SeatHoldCheckouts.abandon_released_seat_holds/1`.
  """
  @spec abandon_released_seat_holds([SeatHoldSchema.t()]) :: :ok
  defdelegate abandon_released_seat_holds(holds), to: SeatHoldCheckouts

  @doc """
  What an attendee returning from Stripe Checkout should be told about their
  booking: still `:processing`, `:failed`, `:awaiting_approval`, `:declined`,
  `:expired`, `:confirmed` or `:cancelled`. See `CheckoutOutcome` for the rules.
  """
  @spec checkout_outcome(BookingPaymentSchema.t() | nil, MeetingSchema.t() | nil) ::
          CheckoutOutcome.t()
  defdelegate checkout_outcome(payment, meeting), to: CheckoutOutcome, as: :classify

  @doc """
  What a booker returning from a held group seat's Stripe Checkout should be
  told, judged by the hold rather than the shared meeting: still
  `:processing`, `:confirmed`, `:cancelled`, `:failed` or `:expired`. See
  `CheckoutOutcome.classify_seat/2` for the rules.
  """
  @spec seat_checkout_outcome(SeatHoldSchema.t() | nil, BookingPaymentSchema.t() | nil) ::
          CheckoutOutcome.t()
  defdelegate seat_checkout_outcome(hold, payment), to: CheckoutOutcome, as: :classify_seat
end
