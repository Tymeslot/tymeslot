defmodule Tymeslot.MeetingPayments.Workers.ExpireCheckoutSession do
  @moduledoc """
  Closes the open Stripe Checkout of a booking cancelled while it awaited
  payment, so its attendee cannot pay for it afterwards
  (`CheckoutSessions.close_checkout/1`).

  Enqueued in the transaction that cancels the booking
  (`CheckoutSessions.schedule_close/1`), so it exists exactly when the
  cancellation does, and Stripe is never called while that transaction
  holds its locks. A Stripe outage is retried. A checkout no longer open is
  done with: one the attendee completed first is refunded in full by the
  completion webhook, and one expired already needs nothing.

  Stripe then sends `checkout.session.expired`, whose handler fails the
  payment (`Webhooks.FailAndExpire`), which takes it off the reconciliation
  sweep. Retries stop well past the checkout's own 30-minute lifetime, by
  when Stripe has expired it regardless.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 8,
    unique: [period: :infinity, keys: [:meeting_id], states: :incomplete]

  alias Tymeslot.MeetingPayments.CheckoutSessions

  @doc "Enqueues the job for `meeting_id`, joining the caller's transaction."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(meeting_id), do: %{meeting_id: meeting_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}),
    do: CheckoutSessions.close_checkout(meeting_id)
end
