defmodule Tymeslot.MeetingPayments.Webhooks.WebhookRegistry do
  @moduledoc """
  Maps Stripe Connect event types to per-event handler modules. The
  registry intentionally only knows about the small set of events the
  meeting-payments feature subscribes to — any other event from Stripe
  is treated as unhandled (returns `nil`) and the processor logs it and
  moves on.
  """

  alias Tymeslot.MeetingPayments.Webhooks.{
    AccountUpdated,
    ChargeDisputeClosed,
    ChargeDisputeCreated,
    ChargeRefunded,
    CheckoutSessionCompleted,
    CheckoutSessionExpired
  }

  @handlers %{
    "checkout.session.completed" => CheckoutSessionCompleted,
    "checkout.session.expired" => CheckoutSessionExpired,
    "charge.refunded" => ChargeRefunded,
    "charge.dispute.created" => ChargeDisputeCreated,
    "charge.dispute.closed" => ChargeDisputeClosed,
    "account.updated" => AccountUpdated
  }

  @spec handler_for(String.t()) :: module() | nil
  def handler_for(event_type), do: Map.get(@handlers, event_type)

  @spec handled_event_types() :: [String.t()]
  def handled_event_types, do: Map.keys(@handlers)
end
