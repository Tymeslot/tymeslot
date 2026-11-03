defmodule Tymeslot.MeetingPayments.Webhooks.DisputeOutcome do
  @moduledoc """
  Reads a Stripe dispute's `status` as the outcome it settles, for the
  `charge.dispute.*` handlers.

    * `:won`: final, and the money stays with the host. Stripe's `won`, and
      the two ways an inquiry ends without a chargeback: `warning_closed`
      (it lapsed or was answered) and `prevented` (it was stopped first).
    * `:lost`: final, and the disputed amount was taken back.
    * `nil`: the dispute is still live (`warning_needs_response`,
      `warning_under_review`, `needs_response`, `under_review`) or the
      status is one Stripe does not document. A live dispute must never be
      cleared by a replayed or mis-routed event.
  """

  @outcomes %{
    "won" => :won,
    "warning_closed" => :won,
    "prevented" => :won,
    "lost" => :lost
  }

  @spec from_status(String.t() | nil) :: :won | :lost | nil
  def from_status(status), do: Map.get(@outcomes, status)
end
