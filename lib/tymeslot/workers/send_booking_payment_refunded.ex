defmodule Tymeslot.Workers.SendBookingPaymentRefunded do
  @moduledoc """
  Sends the attendee email confirming a booking-payment refund.

  Enqueued synchronously by `Tymeslot.MeetingPayments.Refunds.issue_refund/3`
  whenever a refund (full or partial) succeeds. The Stripe `charge.refunded`
  webhook reconciles `refunded_amount_cents` and `status` but does not
  re-enqueue the email — host-initiated refunds are the only path that
  notifies the attendee, matching §7 of the meeting-payments design.

  Loads a fresh booking-payment row inside `perform/1` so the email reflects
  the row's committed state, not whatever was in flight when the job was
  enqueued. Standard Oban retry semantics apply: up to five attempts on
  the `:emails` queue with the platform's CircuitBreaker handling
  upstream-mailer failures.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 1

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded.RefundContext
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingQueries

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => booking_payment_id}}) do
    case MeetingPayments.get_payment(booking_payment_id) do
      nil ->
        Logger.warning("Refund email skipped — booking_payment not found",
          booking_payment_id: booking_payment_id
        )

        {:discard, "booking_payment not found"}

      %BookingPaymentSchema{refunded_amount_cents: 0} ->
        Logger.info("Refund email skipped — no refund recorded on booking_payment",
          booking_payment_id: booking_payment_id
        )

        :ok

      %BookingPaymentSchema{} = payment ->
        send_email(payment)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SendBookingPaymentRefunded missing booking_payment_id",
      args: inspect(args)
    )

    {:discard, "missing booking_payment_id"}
  end

  defp send_email(payment) do
    case build_context(payment) do
      {:ok, context} ->
        deliver(context, payment)

      {:error, :missing_attendee_email} ->
        Logger.warning("Refund email skipped — booking_payment has no attendee_email",
          booking_payment_id: payment.id
        )

        {:discard, "missing attendee_email"}
    end
  end

  defp deliver(context, payment) do
    case context |> BookingPaymentRefunded.render() |> Delivery.deliver() do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Refund email delivery failed",
          booking_payment_id: payment.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp build_context(%BookingPaymentSchema{attendee_email: email}) when email in [nil, ""],
    do: {:error, :missing_attendee_email}

  defp build_context(%BookingPaymentSchema{} = payment) do
    meeting = load_meeting(payment.meeting_id)

    context = %RefundContext{
      attendee_email: payment.attendee_email,
      attendee_name: payment.attendee_name,
      host_name: payment.host_name,
      meeting_title: meeting_title(meeting, payment),
      amount_cents: payment.amount_cents,
      refunded_amount_cents: payment.refunded_amount_cents,
      currency: payment.currency,
      is_full_refund?: payment.refunded_amount_cents >= payment.amount_cents,
      locale: locale_for(meeting)
    }

    {:ok, context}
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

  defp locale_for(%{attendee_locale: locale}) when is_binary(locale) and locale != "", do: locale
  defp locale_for(_meeting), do: "en"
end
