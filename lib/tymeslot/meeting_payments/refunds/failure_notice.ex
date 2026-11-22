defmodule Tymeslot.MeetingPayments.Refunds.FailureNotice do
  @moduledoc """
  Tells whoever must act that a recorded refund ended `failed`: the money
  is still owed to the attendee and Tymeslot will not try again.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.MeetingPayments.RefundSchema

  @doc """
  Reports the failed `refund` to the admins as a `:refund_failed` alert
  naming its payment and `code`, whatever its source. This is the only
  notice sent: the host and the attendee are not told.
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

    :ok
  end
end
