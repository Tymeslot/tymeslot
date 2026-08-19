defmodule Tymeslot.Workers.SendChargeDisputeOpened do
  @moduledoc """
  Sends the host email notifying them that Stripe has opened a dispute on a
  charge linked to one of their booking payments.

  Enqueued from the `charge.dispute.created` webhook handler after the
  `booking_payment` row has been transitioned to `disputed`. Loads a fresh
  booking-payment row inside `perform/1` to avoid acting on stale data.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 0,
    unique: [
      keys: [:booking_payment_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 86_400
    ]

  require Logger

  alias Tymeslot.Emails.Templates.ChargeDisputeOpened
  alias Tymeslot.Emails.Templates.ChargeDisputeOpened.DisputeContext
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => booking_payment_id} = args}) do
    case MeetingPayments.get_payment(booking_payment_id) do
      nil ->
        Logger.warning("Dispute email skipped — booking_payment not found",
          booking_payment_id: booking_payment_id
        )

        {:discard, "booking_payment not found"}

      %BookingPaymentSchema{host_email: host_email}
      when host_email in [nil, ""] ->
        Logger.warning("Dispute email skipped — booking_payment has no host_email",
          booking_payment_id: booking_payment_id
        )

        {:discard, "missing host_email"}

      %BookingPaymentSchema{} = payment ->
        send_email(payment, args)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SendChargeDisputeOpened missing booking_payment_id",
      args: inspect(args)
    )

    {:discard, "missing booking_payment_id"}
  end

  defp send_email(payment, args) do
    context = build_context(payment, args)

    context
    |> ChargeDisputeOpened.render()
    |> TransactionalEmailDelivery.deliver("Dispute email delivery failed",
      booking_payment_id: payment.id
    )
  end

  defp build_context(%BookingPaymentSchema{} = payment, args) do
    meeting = load_meeting(payment.meeting_id)

    %DisputeContext{
      host_email: payment.host_email,
      host_name: payment.host_name,
      amount_cents: payment.amount_cents,
      currency: payment.currency,
      attendee_email: payment.attendee_email,
      attendee_name: payment.attendee_name,
      meeting_title: meeting_title(meeting, payment),
      stripe_charge_id: payment.stripe_charge_id,
      reason: Map.get(args, "reason")
    }
  end

  defp load_meeting(nil), do: nil

  defp load_meeting(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> meeting
      {:error, _reason} -> nil
    end
  end

  defp meeting_title(%{title: title}, _payment) when is_binary(title) and title != "", do: title
  defp meeting_title(_meeting, %{meeting_type_name: name}) when is_binary(name), do: name
  defp meeting_title(_meeting, _payment), do: nil
end
