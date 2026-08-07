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

  A refund failure is reported as `{:error, {:refund_failed, reason}}` and
  leaves the meeting cancelled; see the module docs on ordering.
  """
  @spec cancel(struct() | String.t(), map() | nil, refund_action()) ::
          {:ok, struct()} | {:error, {:refund_failed, term()}} | {:error, term()}
  def cancel(meeting_or_uid, payment, refund_action) do
    with {:ok, cancelled} <- Cancel.execute(meeting_or_uid),
         :ok <- issue_refund(payment, refund_action) do
      {:ok, cancelled}
    end
  end

  defp issue_refund(_payment, :none), do: :ok

  defp issue_refund(payment, {:refund, amount_cents}) do
    case MeetingPayments.issue_refund(payment, amount_cents) do
      {:ok, _payment} -> :ok
      {:error, reason} -> {:error, {:refund_failed, reason}}
    end
  end
end
