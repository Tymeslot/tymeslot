defmodule Tymeslot.MeetingPayments.Refunds.FailureNotice do
  @moduledoc """
  Tells whoever must act that a recorded refund went wrong: it ended
  `failed`, the money still owed to the attendee and Tymeslot not trying
  again; it is stuck pending; or Stripe made it twice.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Workers.SendRefundFailed

  # The sources a host decided: the dialog, a cancellation, a series
  # cancellation. The others refund without anyone acting.
  @host_decided [:host, :cancellation, :series_host]

  @doc """
  Reports the failed `refund` to the admins as a `:refund_failed` alert
  naming its payment and `code`, whatever its source. A refund the host
  decided also emails the host (`Tymeslot.Workers.SendRefundFailed`), who
  holds the money and settles it; the attendee is not told.
  """
  @spec deliver(RefundSchema.t(), String.t()) :: :ok
  def deliver(%RefundSchema{} = refund, code) when is_binary(code) do
    Logger.error("Refund failed for good",
      refund_id: refund.id,
      booking_payment_id: refund.booking_payment_id,
      failure_code: code
    )

    AdminAlerts.report(:refund_failed,
      summary: "A refund of a booking payment failed and the attendee is still owed it",
      context: %{
        refund_id: refund.id,
        booking_payment_id: refund.booking_payment_id,
        source: refund.source,
        failure_code: code
      }
    )

    tell_host(refund)
  end

  defp tell_host(%RefundSchema{source: source} = refund) when source in @host_decided do
    case refund |> SendRefundFailed.new_for() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not queue the refund failure email",
          refund_id: refund.id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  defp tell_host(_refund), do: :ok

  @doc """
  Reports `refund` to the admins as a `:refund_failure_reversed` alert: it
  was settled failed with `failure_code` and reported, and has since been
  recorded as made at Stripe, so that earlier alert no longer stands.

  The host is not emailed again. `SendRefundFailed` sends nothing for a
  refund no longer failed, and a request whose answer never arrived is
  resent under its own key, so a failure Stripe later reverses reaches the
  host only when Stripe answered a request with an error and made its
  refund all the same. For a refund the host decided, the alert says the
  host may have been told, for the admin to put right.
  """
  @spec reversed(RefundSchema.t(), String.t() | nil) :: :ok
  def reversed(%RefundSchema{} = refund, failure_code) do
    AdminAlerts.report(:refund_failure_reversed,
      summary: "A refund reported as failed was made at Stripe after all",
      context: %{
        refund_id: refund.id,
        booking_payment_id: refund.booking_payment_id,
        stripe_refund_id: refund.stripe_refund_id,
        failure_code: failure_code,
        host_may_have_been_told: refund.source in @host_decided
      }
    )

    :ok
  end

  @doc """
  Reports `refund` to the admins as a `:refund_stuck` alert: a job's last
  attempt left it pending, or Stripe refuses to list its charge's refunds.
  It is not failed, as Stripe may have made it, and is tried again: by a
  new job (`Workers.SweepPendingRefunds`), or, when Stripe will not list
  its charge's refunds, by its own job at growing intervals
  (`Workers.ExecuteRefund`). The alert names
  `Tymeslot.Release.settle_stuck_refund/2`, by which an operator who has
  checked the charge at Stripe records how the refund ended.
  """
  @spec stuck(RefundSchema.t()) :: :ok
  def stuck(%RefundSchema{} = refund) do
    Logger.error("Refund still pending after every attempt of its job",
      refund_id: refund.id,
      booking_payment_id: refund.booking_payment_id
    )

    AdminAlerts.report(:refund_stuck,
      summary: "A refund of a booking payment is still pending after every attempt of its job",
      context: %{
        refund_id: refund.id,
        booking_payment_id: refund.booking_payment_id,
        source: refund.source,
        attempt: refund.attempt
      }
    )

    :ok
  end

  @doc """
  Reports to the admins, as a `:refund_duplicated` alert, `stripe_refund`:
  a committed Stripe refund whose metadata names `refund`, which records a
  different Stripe refund, so the attendee was refunded twice. Every
  reconcile of the payment's refunds finds it again; the alert is keyed on
  the Stripe refund, so it is raised once.
  """
  @spec duplicated(RefundSchema.t(), map()) :: :ok
  def duplicated(%RefundSchema{} = refund, stripe_refund) do
    Logger.error("Stripe made a second refund for a recorded refund",
      refund_id: refund.id,
      booking_payment_id: refund.booking_payment_id,
      stripe_refund_id: refund.stripe_refund_id,
      duplicate_stripe_refund_id: stripe_refund["id"]
    )

    AdminAlerts.report(:refund_duplicated,
      summary: "Stripe made a second refund for one refund of a booking payment",
      context: %{
        refund_id: refund.id,
        booking_payment_id: refund.booking_payment_id,
        stripe_refund_id: refund.stripe_refund_id,
        duplicate_stripe_refund_id: stripe_refund["id"],
        duplicate_amount_cents: stripe_refund["amount"]
      }
    )

    :ok
  end
end
