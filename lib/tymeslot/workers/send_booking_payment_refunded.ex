defmodule Tymeslot.Workers.SendBookingPaymentRefunded do
  @moduledoc """
  Sends the attendee email confirming a booking-payment refund.

  Enqueued synchronously by `Tymeslot.MeetingPayments.Refunds.issue_refund/3`
  whenever a refund (full or partial) succeeds, and by
  `Tymeslot.MeetingPayments.Workers.RefundLatePayment` for a refund Stripe
  accepted whose own transaction rolled back. The Stripe `charge.refunded`
  webhook reconciles `refunded_amount_cents` and `status` but does not
  re-enqueue the email — host-initiated refunds are the only path that
  notifies the attendee, matching §7 of the meeting-payments design.

  Loads a fresh booking-payment row inside `perform/1` so the email reflects
  the row's committed state, not whatever was in flight when the job was
  enqueued. The retained host user ID selects the same tested sending identity
  as booking notifications, even after the meeting itself is deleted. Deleted
  hosts are discarded without deriving ownership from retained email addresses.
  Standard bounded retry and circuit-breaker handling apply on the `:emails`
  queue.

  The send is claimed through `Tymeslot.Workers.DeliveryClaims`, so a job the
  Oban lifeline rescues after the email went out does not send it again.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    priority: 1,
    unique: [
      keys: [:booking_payment_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 86_400
    ]

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Emails.BookingDelivery
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded.RefundContext
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  # The payment is gone, or the recipient already raised its own alert;
  # missing ids and a payment without an attendee email are recorded.
  @payment_gone "booking_payment not found"
  @host_gone "booking payment host not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@payment_gone, @host_gone] or
        TransactionalEmailDelivery.recipient_rejected?(reason)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => booking_payment_id}} = job) do
    case MeetingPayments.get_payment(booking_payment_id) do
      nil ->
        Logger.warning("Refund email skipped — booking_payment not found",
          booking_payment_id: booking_payment_id
        )

        {:discard, @payment_gone}

      %BookingPaymentSchema{refunded_amount_cents: 0} ->
        Logger.info("Refund email skipped — no refund recorded on booking_payment",
          booking_payment_id: booking_payment_id
        )

        :ok

      %BookingPaymentSchema{} = payment ->
        send_email(payment, job)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SendBookingPaymentRefunded missing booking_payment_id",
      args: LogFormat.reason(args)
    )

    {:discard, "missing booking_payment_id"}
  end

  defp send_email(payment, job) do
    with {:ok, _details, sender} <- prepare_sender(payment),
         {:ok, context} <- build_context(payment) do
      context = %{context | email_sender: sender}
      DeliveryClaims.once(job, "refund_email", fn -> deliver(context, payment, job) end)
    else
      {:error, :missing_attendee_email} ->
        Logger.warning("Refund email skipped — booking_payment has no attendee_email",
          booking_payment_id: payment.id
        )

        {:discard, "missing attendee_email"}

      {:error, :owner_not_found} ->
        Logger.info("Refund email skipped — booking payment host not found",
          booking_payment_id: payment.id
        )

        {:discard, @host_gone}

      {:error, reason} ->
        TransactionalEmailDelivery.handle_failure(reason, "Refund sender resolution failed",
          booking_payment_id: payment.id,
          executions: SnoozePolicy.executions(job)
        )
    end
  end

  defp deliver(context, payment, job) do
    context
    |> BookingPaymentRefunded.render()
    |> TransactionalEmailDelivery.deliver(
      job,
      "Refund email delivery failed",
      [booking_payment_id: payment.id],
      sender: context.email_sender
    )
  end

  # A payment deliberately retains its host ID after meeting/account deletion.
  # Check the account even with routing disabled: an orphaned retention row must
  # never recover credentials or infer a new owner from a recycled email address.
  defp prepare_sender(%BookingPaymentSchema{host_user_id: id, host_deleted_at: nil})
       when is_integer(id) and id > 0 do
    case Auth.get_user(id) do
      {:ok, _host} -> BookingDelivery.prepare(%{organizer_user_id: id})
      {:error, :not_found} -> {:error, :owner_not_found}
    end
  end

  defp prepare_sender(_payment), do: {:error, :owner_not_found}

  defp build_context(%BookingPaymentSchema{attendee_email: email}) when email in [nil, ""],
    do: {:error, :missing_attendee_email}

  defp build_context(%BookingPaymentSchema{} = payment) do
    meeting = load_meeting(payment.meeting_id)

    context = %RefundContext{
      attendee_email: payment.attendee_email,
      attendee_name: payment.attendee_name,
      host_email: payment.host_email,
      host_name: payment.host_name,
      meeting_title: meeting_title(meeting, payment),
      amount_cents: payment.amount_cents,
      refunded_amount_cents: payment.refunded_amount_cents,
      currency: payment.currency,
      is_full_refund?: payment.refunded_amount_cents >= payment.amount_cents,
      locale: RecipientLocale.attendee_locale(meeting)
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

  # The refund notice goes to the booker, so the title is in their language.
  defp meeting_title(%{title: title} = meeting, _payment) when is_binary(title) and title != "",
    do: BookingTitle.localise(meeting, RecipientLocale.attendee_locale(meeting))

  defp meeting_title(_meeting, %{meeting_type_name: name}) when is_binary(name), do: name
  defp meeting_title(_meeting, _payment), do: nil
end
