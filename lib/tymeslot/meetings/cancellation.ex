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
  attendee paid for a meeting that is not going to happen. The host can
  override that with a partial amount, or with no refund at all — but declining
  to refund is the one choice that requires an explicit acknowledgement, since
  it is the only one that leaves the attendee out of pocket.

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
  alias Tymeslot.MeetingPayments

  @typedoc "What to refund: nothing, or a positive amount in minor units."
  @type refund_action :: :none | {:refund, pos_integer()}

  @typedoc """
  Why a requested refund could not be turned into an action.

    * `:acknowledgement_required` — cancelling without a refund was chosen but
      not acknowledged.
    * `:exceeds_remaining` — more than the refundable balance was requested.
    * `:invalid_amount` — the amount could not be read as money.
  """
  @type refund_error :: :acknowledgement_required | :exceeds_remaining | :invalid_amount

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

    case parsed do
      {:ok, cents} -> {:ok, {:refund, cents}}
      {:error, :exceeds_remaining} -> {:error, :exceeds_remaining}
      {:error, _reason} -> {:error, :invalid_amount}
    end
  end

  # No explicit choice: refund whatever is left, or nothing if the balance has
  # already been refunded in full.
  def resolve_refund(payment, _params) do
    case MeetingPayments.refundable_remaining_cents(payment) do
      remaining when remaining > 0 -> {:ok, {:refund, remaining}}
      _zero -> {:ok, :none}
    end
  end

  @doc """
  Cancels the meeting, then issues the resolved refund.

  `acting_user_id` is whoever asked for the cancellation. Anyone the caller
  allows to cancel may cancel without a refund, but a refund moves the host's
  money, so only the host who took the payment may ask for one. Anyone else
  asking for a refund gets `{:error, :not_found}`, returned before the meeting
  is touched: a refusal is not a failed refund, and must not leave a cancelled
  meeting behind.

  A refund failure is reported as `{:error, {:refund_failed, reason}}` and
  leaves the meeting cancelled; see the module docs on ordering.
  """
  @spec cancel(struct(), integer(), refund_action()) ::
          {:ok, struct()}
          | {:error, :not_found}
          | {:error, {:refund_failed, term()}}
          | {:error, term()}
  def cancel(meeting, _acting_user_id, :none), do: Cancel.execute(meeting)

  def cancel(%{id: meeting_id} = meeting, acting_user_id, {:refund, amount_cents}) do
    case MeetingPayments.payment_for_meeting(meeting_id, acting_user_id) do
      nil -> {:error, :not_found}
      payment -> cancel_and_refund(meeting, payment, acting_user_id, amount_cents)
    end
  end

  # The announcement waits for the refund, whichever way it went: the host's
  # cancellation email reports what they still hold for the booking, read from
  # the payment when the email is built.
  defp cancel_and_refund(meeting, payment, host_user_id, amount_cents) do
    with {:ok, cancelled} <- Cancel.execute(meeting, announce: false) do
      try do
        case MeetingPayments.refund_payment_for_host(payment.id, host_user_id, amount_cents) do
          {:ok, _payment} -> {:ok, cancelled}
          {:error, reason} -> {:error, {:refund_failed, reason}}
        end
      after
        Cancel.announce(cancelled)
      end
    end
  end
end
