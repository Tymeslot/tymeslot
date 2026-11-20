defmodule Tymeslot.Meetings.Cancellation do
  @moduledoc """
  Cancelling a paid meeting, and deciding what the attendee gets back.

  Cancellation and refunding are one decision for the host but two systems
  underneath: the meeting is local state, the refund is a Stripe call that
  cannot be rolled back. This module owns the rule connecting them so that the
  rule is stated once, rather than reconstructed at each place a host can
  cancel from.

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
  with a live booking they have been paid back for. In this order the bad case
  is a cancelled meeting with no refund, which is visible to the host and can
  be settled manually from Stripe — hence the distinct `:refund_failed` reason,
  so callers can say so rather than reporting a failed cancellation.

  The cancellation is announced third, once the refund has settled either
  way. The host's cancellation email tells them what they still hold for the
  booking, and it reads the payment when it is built: announced before the
  refund, it would report the full amount as outstanding for a refund that
  went through a moment later.
  """

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.MeetingPayments

  @refusals [:not_paid, :outside_refund_window, :under_dispute]

  @typedoc "Why a payment can no longer be refunded (`MeetingPayments.refund_refusal/1`)."
  @type refund_refusal :: :not_paid | :outside_refund_window | :under_dispute

  @typedoc """
  What to refund: nothing, a positive amount in minor units, or nothing
  because the payment can no longer be refunded (and why).
  """
  @type refund_action :: :none | {:refund, pos_integer()} | {:not_refunded, refund_refusal()}

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
  Cancels the meeting, then issues the resolved refund.

  `acting_user_id` is whoever asked for the cancellation, and must be the
  meeting's organiser (`organizer_user_id`): this cancels as the organiser,
  which for a group meeting releases every seat. A refund moves the host's
  money, so it also needs the payment to be the acting organiser's. Anyone
  else gets `{:error, :not_found}`, returned before the meeting is touched: a
  refusal is not a failed cancellation or refund, and must not leave a
  cancelled meeting behind.

  A refund failure is reported as `{:error, {:refund_failed, reason}}` and
  leaves the meeting cancelled; see the module docs on ordering.
  """
  @spec cancel(struct(), integer() | nil, refund_action()) ::
          {:ok, struct()}
          | {:error, :not_found}
          | {:error, {:refund_failed, term()}}
          | {:error, term()}
  # A session of an open series request is answered with its series
  # (decline, from the request), never cancelled on its own: the dashboard
  # offers no cancel for it, and a crafted event is refused here. A
  # confirmed session the booker moved back into the approval gate is a
  # request of its own (`SeriesApproval.series_request?/1` is false for it),
  # cancelled like any single booking awaiting approval.
  def cancel(%{organizer_user_id: owner_id} = meeting, acting_user_id, refund_action)
      when is_integer(owner_id) and owner_id == acting_user_id do
    if SeriesApproval.series_request?(meeting),
      do: {:error, {:not_cancellable, :held_for_series_approval}},
      else: cancel_as_organizer(meeting, acting_user_id, refund_action)
  end

  def cancel(_meeting, _acting_user_id, _refund_action), do: {:error, :not_found}

  defp cancel_as_organizer(meeting, _organizer_user_id, :none),
    do: Cancel.execute(meeting, caller: :organizer)

  defp cancel_as_organizer(meeting, _organizer_user_id, {:not_refunded, _reason}),
    do: Cancel.execute(meeting, caller: :organizer)

  defp cancel_as_organizer(
         %{id: meeting_id} = meeting,
         organizer_user_id,
         {:refund, amount_cents}
       ) do
    case MeetingPayments.payment_for_meeting(meeting_id, organizer_user_id) do
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
  # A meeting is cancelled once, so it and the amount name the refund.
  defp cancel_and_refund(meeting, payment, host_user_id, amount_cents) do
    key = "cancel_refund:#{meeting.id}:#{amount_cents}"

    with {:ok, cancelled} <- Cancel.execute(meeting, caller: :organizer, announce: false) do
      try do
        case MeetingPayments.refund_payment_for_host(payment.id, host_user_id, amount_cents, key) do
          {:ok, _payment} -> {:ok, cancelled}
          {:error, reason} -> {:error, {:refund_failed, reason}}
        end
      after
        Cancel.announce(cancelled)
      end
    end
  end
end
