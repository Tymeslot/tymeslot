defmodule Tymeslot.Meetings.Cancellation do
  @moduledoc """
  Cancelling a paid meeting, and deciding what the attendee gets back.

  Cancellation and refunding are one decision for the host but two systems
  underneath: the meeting is local state, the refund is a Stripe call that
  cannot be rolled back. This module owns the rule connecting them so that the
  rule is stated once, rather than reconstructed at each place a host can
  cancel from. The refund is recorded with the decision
  (`MeetingPayments.refund_now/4`) and finished by Tymeslot: a refund Stripe
  has not confirmed yet stays pending and is retried until it goes through.

  ## The refund rule

  Cancelling a paid meeting refunds the full remaining balance by default: the
  attendee paid for a meeting that is not going to happen. A session of a
  paid series refunds one session's price by default, as its one payment
  paid for the sessions that still go ahead too. The host can
  override that with a partial amount, or with no refund at all — but declining
  to refund is the one choice that requires an explicit acknowledgement, since
  it is the only one that leaves the attendee out of pocket.

  A payment Tymeslot can no longer refund (`MeetingPayments.refund_refusal/1`:
  past the refund window, under dispute, never paid) is settled up front:
  the default resolves to cancelling without a refund, with the reason
  (`{:not_refunded, reason}`), so the host is told why rather than seeing a
  refund fail after the meeting is already cancelled; an explicit amount is
  refused with that reason before anything is cancelled.

  ## Ordering

  The meeting is cancelled first and refunded second. The reverse order would
  risk refunding an attendee whose meeting then fails to cancel, leaving them
  with a live booking they have been paid back for. A refund Stripe has not
  answered yet is no failure (`{:ok, cancelled, :refund_pending}`): it is
  recorded and Tymeslot keeps trying. The bad case is a refund Stripe
  declined, leaving a cancelled meeting with no refund, which is visible to
  the host and can be settled manually from Stripe; hence the distinct
  `:refund_failed` reason, so callers can say so rather than reporting a
  failed cancellation.

  The cancellation is announced third, once the refund has settled either
  way. The host's cancellation email tells them what they still hold for the
  booking, and it reads the payment when it is built: announced before the
  refund, it would report the full amount as outstanding for a refund that
  went through a moment later.

  ## A group session

  A group session has one payment per paid seat, not one for the meeting.
  The host cancelling it refunds every paid seat in full by default, or
  none, which again needs the acknowledgement (`resolve_seat_refund/2`); a
  partial amount is a per-payment action on the payments page, not a
  choice here. A participant leaving their own seat is refunded nothing
  automatically.

  Only the seats live when the host cancels are refunded
  (`BookingPayments.seat_payments_for_meeting/2`): a payment linked to a
  participant who has not cancelled. A payment whose hold never became a
  seat is settled by its own path, and a participant who left earlier is
  not refunded for having left, so neither is refunded here; the host can
  still refund the latter from the payments page. A seat under dispute is
  not refunded now, its money being with the card network, but its refund
  is recorded as held back by the dispute
  (`MeetingPayments.request_remaining_refund/3`), so a dispute the host
  later wins refunds the attendee what came back
  (`Webhooks.ChargeDisputeClosed`). That follows the host's choice: a
  host who chose no refund records none. A session whose only paid seats
  are disputed offers the host no choice, and is settled as the default,
  a full refund.

  The seats are settled in the cancellation's own transaction, once the
  meeting row is cancelled and so locked (`Cancel.execute_settling/3`):
  every seat hold still open is released as `:meeting_cancelled`, and a
  refund of what each paid seat still inside the 60-day refund window has
  left is recorded (`MeetingPayments.request_refund/4`, source
  `:cancellation`); a seat paid before that is left for the host to refund
  from Stripe, as the dialog and the organiser's email say. Read under that
  lock, the seats include one paid while the cancellation waited for it. A
  recorded refund is made by its own job (`Workers.ExecuteRefund`) once the
  cancellation commits, never under the lock, so a refund that fails leaves
  the session cancelled, and the host is told (`Refunds.FailureNotice`).
  Once committed, each released hold's checkout is expired
  (a payment completing anyway is refunded, its hold having been released
  for a cancelled meeting) and its booker's payment page told, and the
  cancellation is announced. The organiser's email is told of the seats
  settled under the lock and what each held then (`t:seat_refund/0`), so it
  names exactly the refunds recorded, or the money left with the host.
  """

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.SeatHolds

  @refusals [:not_paid, :outside_refund_window, :under_dispute]

  @typedoc "Why a payment can no longer be refunded (`MeetingPayments.refund_refusal/1`)."
  @type refund_refusal :: :not_paid | :outside_refund_window | :under_dispute

  @typedoc """
  What a host's cancellation of a group session did with its paid seats'
  money, for the organiser's cancellation email: refunded every seat
  (`:full`) or none (`:none`), how many seats Tymeslot can refund, and what
  they still held in each currency when the cancellation settled them.
  `:outside_window` counts and totals the seats paid more than 60 days
  before, which no choice refunds: only the host's Stripe dashboard can.
  Present only when a seat was paid.
  """
  @type seat_refund :: %{
          choice: :full | :none,
          count: non_neg_integer(),
          totals: [%{currency: String.t(), amount_cents: non_neg_integer()}],
          outside_window: %{
            count: non_neg_integer(),
            totals: [%{currency: String.t(), amount_cents: non_neg_integer()}]
          }
        }

  @typedoc """
  What to refund: nothing, a positive amount in minor units, nothing
  because the payment can no longer be refunded (and why), or, for a group
  session, every paid seat in full (`:refund_seats`).
  """
  @type refund_action ::
          :none | {:refund, pos_integer()} | {:not_refunded, refund_refusal()} | :refund_seats

  @typedoc """
  Why a requested refund could not be turned into an action.

    * `:acknowledgement_required` — cancelling without a refund was chosen but
      not acknowledged.
    * `:exceeds_remaining` — more than the refundable balance was requested.
    * `:invalid_amount` — the amount could not be read as money.
    * a `t:refund_refusal/0` — an amount was asked of a payment that can no
      longer be refunded.
  """
  @type refund_error ::
          :acknowledgement_required | :exceeds_remaining | :invalid_amount | refund_refusal()

  @doc """
  Works out which refund the host's choice implies.

  Takes the raw cancellation form params so the decision lives here rather than
  in whichever surface collected them. An unpaid meeting (`nil` payment) always
  resolves to `:none`.
  """
  @spec resolve_refund(map() | nil, map()) :: {:ok, refund_action()} | {:error, refund_error()}
  def resolve_refund(nil, _params), do: {:ok, :none}

  def resolve_refund(_payment, %{"cancel_refund_choice" => "none"} = params) do
    if params["cancel_refund_no_refund_ack"] == "true" do
      {:ok, :none}
    else
      {:error, :acknowledgement_required}
    end
  end

  def resolve_refund(payment, %{"cancel_refund_choice" => "partial"} = params) do
    parsed =
      MeetingPayments.parse_refund_amount(payment, %{
        "refund_type" => "partial",
        "amount" => params["cancel_refund_amount"]
      })

    with {:ok, cents} <- parsed,
         :ok <- MeetingPayments.refund_refusal(payment) do
      {:ok, {:refund, cents}}
    else
      {:error, reason} when reason in [:exceeds_remaining | @refusals] -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_amount}
    end
  end

  # No explicit choice: refund whatever is left, or nothing if the balance has
  # already been refunded in full. A session of a paid series refunds one
  # session's price: the payment paid for every session, and the others go
  # ahead. A payment that can no longer be refunded cancels without one,
  # and says why.
  def resolve_refund(payment, _params) do
    case MeetingPayments.default_cancellation_refund_cents(payment) do
      remaining when remaining > 0 -> default_refund(payment, remaining)
      _zero -> {:ok, :none}
    end
  end

  defp default_refund(payment, cents) do
    case MeetingPayments.refund_refusal(payment) do
      :ok -> {:ok, {:refund, cents}}
      {:error, reason} -> {:ok, {:not_refunded, reason}}
    end
  end

  @doc """
  Works out what cancelling a group session refunds, from its paid seats
  (`BookingPayments.seat_payments_for_meeting/2`) and the host's choice:
  every seat in full (`:refund_seats`), unless the host chose no refund and
  acknowledged it. A partial choice still refunds every seat in full: a
  partial amount is a per-payment action. No paid seats refund nothing.
  """
  @spec resolve_seat_refund([BookingPaymentSchema.t()], map()) ::
          {:ok, :refund_seats | :none} | {:error, :acknowledgement_required}
  def resolve_seat_refund([], _params), do: {:ok, :none}

  def resolve_seat_refund(_payments, %{"cancel_refund_choice" => "none"} = params) do
    if params["cancel_refund_no_refund_ack"] == "true",
      do: {:ok, :none},
      else: {:error, :acknowledgement_required}
  end

  def resolve_seat_refund(_payments, _params), do: {:ok, :refund_seats}

  @doc """
  Cancels the meeting, then issues the resolved refund.

  `acting_user_id` is whoever asked for the cancellation, and must be the
  meeting's organiser (`organizer_user_id`): this cancels as the organiser,
  which for a group meeting releases every seat. A refund moves the host's
  money, so it also needs the payment to be the acting organiser's. Anyone
  else gets `{:error, :not_found}`, returned before the meeting is touched: a
  refusal is not a failed cancellation or refund, and must not leave a
  cancelled meeting behind.

  A refund Stripe has not confirmed yet returns
  `{:ok, cancelled, :refund_pending}`; one refused is reported as
  `{:error, {:refund_failed, reason}}` and leaves the meeting cancelled; see
  the module docs on ordering.

  A group session is settled seat by seat (see "A group session" above),
  whatever the action: `:refund_seats` (or an amount) records a full
  refund of every paid seat, `:none` (or a refusal) refunds none, and
  either releases the seats still held for bookers paying. Its refunds
  are made in the background, so it never returns `:refund_pending` or
  `{:refund_failed, _}`.
  `:refund_seats` on a one-to-one meeting, which has no seats, is
  `{:error, :not_found}`, with nothing cancelled.

  `seat_payment_ids:` names the paid seats the host's choice was made
  against (the cancel dialog's). A group session whose paid seats, read
  under the meeting's lock, are any others (one paid or refunded since)
  is not cancelled: `{:error, {:payments_changed, payments}}` returns them
  as they now stand, for the host to choose again. Without it, whatever
  seats are paid are settled.
  """
  @spec cancel(struct(), integer() | nil, refund_action(), keyword()) ::
          {:ok, struct()}
          | {:ok, struct(), :refund_pending}
          | {:error, :not_found}
          | {:error, {:refund_failed, term()}}
          | {:error, {:payments_changed, [BookingPaymentSchema.t()]}}
          | {:error, term()}
  # A session of an open series request is answered with its series
  # (decline, from the request), never cancelled on its own: the dashboard
  # offers no cancel for it, and a crafted event is refused here. A
  # confirmed session the booker moved back into the approval gate is a
  # request of its own (`SeriesApproval.series_request?/1` is false for it),
  # cancelled like any single booking awaiting approval.
  def cancel(meeting, acting_user_id, refund_action, opts \\ [])

  def cancel(%{organizer_user_id: owner_id} = meeting, acting_user_id, refund_action, opts)
      when is_integer(owner_id) and owner_id == acting_user_id do
    if SeriesApproval.series_request?(meeting),
      do: {:error, {:not_cancellable, :held_for_series_approval}},
      else: cancel_as_organizer(meeting, acting_user_id, refund_action, opts)
  end

  def cancel(_meeting, _acting_user_id, _refund_action, _opts), do: {:error, :not_found}

  # A group meeting is always settled seat by seat, whichever action
  # came in: its seats are never one payment. Nothing but `:none` or a
  # refusal (nothing left that can be refunded) declines the refund; an
  # amount refunds every seat in full, as `resolve_seat_refund/2` resolves
  # a partial choice.
  defp cancel_as_organizer(meeting, organizer_user_id, refund_action, opts) do
    if Meetings.group?(meeting),
      do:
        cancel_group(
          meeting,
          organizer_user_id,
          refunds_seats?(refund_action),
          Keyword.get(opts, :seat_payment_ids)
        ),
      else: cancel_one_to_one(meeting, organizer_user_id, refund_action)
  end

  defp refunds_seats?(:none), do: false
  defp refunds_seats?({:not_refunded, _reason}), do: false
  defp refunds_seats?(:refund_seats), do: true
  defp refunds_seats?({:refund, _amount_cents}), do: true

  # A one-to-one meeting has no seats to refund.
  defp cancel_one_to_one(_meeting, _organizer_user_id, :refund_seats), do: {:error, :not_found}

  defp cancel_one_to_one(meeting, _organizer_user_id, :none),
    do: Cancel.execute(meeting, caller: :organizer)

  defp cancel_one_to_one(meeting, _organizer_user_id, {:not_refunded, _reason}),
    do: Cancel.execute(meeting, caller: :organizer)

  defp cancel_one_to_one(%{id: meeting_id} = meeting, organizer_user_id, {:refund, amount_cents}) do
    case BookingPayments.payment_for_meeting(meeting_id, organizer_user_id) do
      nil -> {:error, :not_found}
      payment -> cancel_and_refund(meeting, payment, organizer_user_id, amount_cents)
    end
  end

  # `caller: :organizer` is what lets this cancel a group meeting outright.
  # The public, participant-facing cancel link resolves through
  # `Meetings.cancel_meeting/1` instead, which passes no `:caller` and is
  # therefore refused for a group slot: one booker must not be able to cancel
  # everyone else's seats. This module is only ever reached from the
  # authenticated dashboard, where cancelling the whole meeting is the host's
  # own decision.
  #
  # The announcement waits for the refund, whichever way it went: the host's
  # cancellation email reports what they still hold for the booking, read from
  # the payment when the email is built.
  #
  # A refund left pending (`:stuck` included) is Tymeslot's to finish.
  defp cancel_and_refund(meeting, payment, host_user_id, amount_cents) do
    with {:ok, cancelled} <- Cancel.execute(meeting, caller: :organizer, announce: false) do
      try do
        case MeetingPayments.refund_now(payment, amount_cents, :cancellation,
               host_user_id: host_user_id
             ) do
          {:ok, _refund} ->
            {:ok, cancelled}

          {pending, _refund} when pending in [:pending, :stuck] ->
            {:ok, cancelled, :refund_pending}

          {:error, reason} ->
            {:error, {:refund_failed, reason}}
        end
      after
        Cancel.announce(cancelled)
      end
    end
  end

  defp cancel_group(meeting, organizer_user_id, refund?, seen_ids) do
    settle = &settle_seats(&1, organizer_user_id, refund?, seen_ids)

    case Cancel.execute_settling(meeting, settle, caller: :organizer, announce: false) do
      # A request still awaiting approval is withdrawn, not cancelled, and
      # runs no settlement: nothing of it was paid for as a seat.
      {:ok, withdrawn, nil} ->
        Cancel.announce(withdrawn)
        {:ok, withdrawn}

      {:ok, cancelled, settled} ->
        Checkout.abandon_released_seat_holds(settled.released_holds)
        Cancel.announce(cancelled, seat_refund_opts(settled, refund?))
        {:ok, cancelled}

      {:error, _reason} = error ->
        error
    end
  end

  # Inside the cancellation's transaction, the meeting row cancelled and
  # locked: the holds are released before anything else, after the
  # meeting (the lock order every writer of a hold keeps), and the paid
  # seats are read under the lock, so one paid while the cancellation
  # waited for the lock is among them. No pending payment is locked here.
  #
  # Only the seats live now are refunded, read once and split into those
  # with money outstanding and those a dispute holds
  # (`BookingPayments.live_seat_payments_for_meeting/2`): a dispute closing
  # meanwhile locks its payment only, never the meeting, so two reads could
  # see the seat in neither. A disputed seat's money is with the card
  # network. Its refund is recorded held back by the dispute instead
  # (`hold_disputed_refunds/3`), for the dispute's close to make should the
  # money come back to the host. The host chose against
  # the seats they were shown, which never include a disputed one, so with
  # none shown there was no choice to make and the default, a full refund,
  # applies.
  #
  # A seat paid more than 60 days ago is past the refund window
  # (`BookingPayments.split_by_refund_window/1`): no refund is recorded for
  # it, which would only be refused, and the email tells the host to refund
  # it from Stripe.
  #
  # Each refund is sized and recorded under its payment's row lock, so a
  # refund or dispute that landed since the read is accounted for rather
  # than failing the cancellation. That lock is taken after the meeting's,
  # the order `Tymeslot.BookingSeries.Cancel` takes for a series payment
  # too. No writer holding a seat payment's row lock waits on
  # its meeting's: the paths that lock both (`Webhooks.SeatCheckoutCompleted`)
  # do so only for a payment still pending, never one already paid.
  #
  # The seats read here are the ones settled, so they must be the ones the
  # host chose against (`seen_ids`): any others roll the cancellation back.
  defp settle_seats(cancelled, organizer_user_id, refund?, seen_ids) do
    released = SeatHolds.release_open_for_meeting(cancelled.id, :meeting_cancelled)

    {payments, disputed} =
      BookingPayments.live_seat_payments_for_meeting(cancelled.id, organizer_user_id)

    {refundable, _outside_window} = BookingPayments.split_by_refund_window(payments)

    # What each seat holds is read before its refund is recorded, which
    # counts as pending against it from then on.
    seat_money = BookingPayments.seat_money(payments)

    with :ok <- seen(payments, seen_ids),
         {:ok, scheduled} <- schedule_refunds(refundable, organizer_user_id, refund?),
         :ok <- hold_disputed_refunds(disputed, organizer_user_id, refund? or payments == []) do
      {:ok, %{released_holds: released, refunds_scheduled: scheduled, seat_money: seat_money}}
    end
  end

  defp seen(_payments, nil), do: :ok

  defp seen(payments, seen_ids) do
    if MapSet.new(payments, & &1.id) == MapSet.new(seen_ids),
      do: :ok,
      else: {:error, {:payments_changed, payments}}
  end

  defp schedule_refunds(_payments, _organizer_user_id, false), do: {:ok, 0}

  defp schedule_refunds(payments, organizer_user_id, true) do
    Enum.reduce_while(payments, {:ok, 0}, fn payment, {:ok, count} ->
      case record_refund(payment, organizer_user_id) do
        {:ok, :none} -> {:cont, {:ok, count}}
        {:ok, _refund} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Each payment is locked and read afresh: a dispute that closed while the
  # cancellation waited leaves a payment refunded as any other seat, one it
  # took all of leaves nothing to refund.
  defp hold_disputed_refunds(_payments, _organizer_user_id, false), do: :ok

  defp hold_disputed_refunds(payments, organizer_user_id, true) do
    Enum.reduce_while(payments, :ok, fn payment, :ok ->
      case MeetingPayments.request_remaining_refund(payment.id, organizer_user_id, :cancellation) do
        {:ok, _refund_or_none} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # What the seat has left, less any refund of it still pending, read under
  # its row lock: a seat whose pending or settled refunds already hold all
  # of it records none, and one disputed since the read is held back by
  # the dispute as `hold_disputed_refunds/3` holds it.
  defp record_refund(payment, organizer_user_id),
    do: MeetingPayments.request_remaining_refund(payment.id, organizer_user_id, :cancellation)

  # The organiser's email says what happens to the money only when somebody
  # paid, and names the very seats settled above, at what each still held:
  # the same seats and sums whether they are being refunded or not.
  defp seat_refund_opts(%{seat_money: %{count: 0, outside_window: %{count: 0}}}, _refund?),
    do: []

  defp seat_refund_opts(%{seat_money: money}, refund?),
    do: [seat_refund: Map.put(money, :choice, if(refund?, do: :full, else: :none))]
end
