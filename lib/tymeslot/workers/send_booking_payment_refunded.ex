defmodule Tymeslot.Workers.SendBookingPaymentRefunded do
  @moduledoc """
  Sends the attendee email confirming a booking-payment refund.

  Enqueued by `Tymeslot.MeetingPayments.Refunds.Settlement` in the
  transaction that settles a recorded refund (full or partial) as
  succeeded, whatever decided it and whoever settles it (a refund attempt,
  or `charge.refunded` reconciling a pending refund), so one refund sends
  one email; and by `Tymeslot.MeetingPayments.Workers.RefundLatePayment`
  for a refund made under its old key that `charge.refunded` recorded. A
  refund made outside Tymeslot (in the Stripe dashboard), which
  `charge.refunded` records as external, sends no email.

  Loads a fresh booking-payment row inside `perform/1` so the email reflects
  the row's committed state, not whatever was in flight when the job was
  enqueued. Standard Oban retry semantics apply: up to five attempts on
  the `:emails` queue with the platform's CircuitBreaker handling
  upstream-mailer failures.

  The email names the refunds made at Stripe
  (`MeetingPayments.stripe_refunded_cents/1`), never what a lost dispute
  took back: the attendee's bank has told them about the chargeback, and
  a payment that only a dispute repaid sends nothing.

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

  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded.RefundContext
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  # The payment is gone, or the recipient already raised its own alert;
  # missing ids and a payment without an attendee email are recorded.
  @payment_gone "booking_payment not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason in [@payment_gone] or TransactionalEmailDelivery.recipient_rejected?(reason)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => booking_payment_id}} = job) do
    case BookingPayments.get_payment(booking_payment_id) do
      nil ->
        Logger.warning("Refund email skipped — booking_payment not found",
          booking_payment_id: booking_payment_id
        )

        {:discard, @payment_gone}

      %BookingPaymentSchema{} = payment ->
        if MeetingPayments.stripe_refunded_cents(payment) > 0 do
          send_email(payment, job)
        else
          Logger.info("Refund email skipped — no refund recorded on booking_payment",
            booking_payment_id: booking_payment_id
          )

          :ok
        end
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SendBookingPaymentRefunded missing booking_payment_id",
      args: LogFormat.reason(args)
    )

    {:discard, "missing booking_payment_id"}
  end

  defp send_email(payment, job) do
    case build_context(payment) do
      {:ok, context} ->
        DeliveryClaims.once(job, "refund_email", fn -> deliver(context, payment, job) end)

      {:error, :missing_attendee_email} ->
        Logger.warning("Refund email skipped — booking_payment has no attendee_email",
          booking_payment_id: payment.id
        )

        {:discard, "missing attendee_email"}
    end
  end

  defp deliver(context, payment, job) do
    context
    |> BookingPaymentRefunded.render()
    |> TransactionalEmailDelivery.deliver(job, "Refund email delivery failed",
      booking_payment_id: payment.id
    )
  end

  defp build_context(%BookingPaymentSchema{attendee_email: email}) when email in [nil, ""],
    do: {:error, :missing_attendee_email}

  defp build_context(%BookingPaymentSchema{} = payment) do
    # A series payment is named after its first session.
    meeting = payment |> BookingPayments.meetings_for_payment() |> List.first()
    refunded = MeetingPayments.stripe_refunded_cents(payment)
    locale = booker_locale(payment, meeting)

    context = %RefundContext{
      attendee_email: payment.attendee_email,
      attendee_name: payment.attendee_name,
      host_email: payment.host_email,
      host_name: payment.host_name,
      meeting_title: meeting_title(meeting, payment, locale),
      amount_cents: payment.amount_cents,
      refunded_amount_cents: refunded,
      currency: payment.currency,
      is_full_refund?: refunded >= payment.amount_cents,
      locale: locale
    }

    {:ok, context}
  end

  # The refund notice goes to the booker, so the booking is named from their
  # side, "<meeting type> with <host>", in their language. The stored title
  # names the booker instead, being the host's calendar event.
  defp meeting_title(meeting, payment, locale) do
    case meeting_type_name(meeting, payment) do
      nil ->
        nil

      type ->
        Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
          title_with_host(type, payment.host_name)
        end)
    end
  end

  # A seat's payment belongs to one booker on a group meeting, whose own
  # `attendee_locale` is the first booker's (or the default, for a session the
  # host planned). The seat's language is its participant's, or its hold's
  # while the seat was never confirmed.
  defp booker_locale(%BookingPaymentSchema{seat_payment: true} = payment, meeting) do
    case Repo.preload(payment, [:participant, :seat_hold]) do
      %{participant: %{locale: locale}} when is_binary(locale) ->
        RecipientLocale.attendee_locale(%{attendee_locale: locale})

      %{seat_hold: %{locale: locale}} when is_binary(locale) ->
        RecipientLocale.attendee_locale(%{attendee_locale: locale})

      _payment ->
        RecipientLocale.attendee_locale(meeting)
    end
  end

  defp booker_locale(_payment, meeting), do: RecipientLocale.attendee_locale(meeting)

  defp meeting_type_name(%{meeting_type: type}, _payment) when is_binary(type) and type != "",
    do: type

  defp meeting_type_name(_meeting, %{meeting_type_name: type})
       when is_binary(type) and type != "",
       do: type

  defp meeting_type_name(_meeting, _payment), do: nil

  defp title_with_host(type, host) when is_binary(host) and host != "",
    do: BookingTitle.render(type, host)

  defp title_with_host(type, _host), do: type
end
