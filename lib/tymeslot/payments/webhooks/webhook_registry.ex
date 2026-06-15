defmodule Tymeslot.Payments.Webhooks.WebhookRegistry do
  @moduledoc """
  Registry for webhook event handlers.
  """

  @webhook_handlers [
    Tymeslot.Payments.Webhooks.CheckoutSessionHandler,
    Tymeslot.Payments.Webhooks.CheckoutSessionExpiredHandler,
    Tymeslot.Payments.Webhooks.ChargeHandler,
    Tymeslot.Payments.Webhooks.PaymentMethodHandler,
    Tymeslot.Payments.Webhooks.PaymentIntentHandler,
    Tymeslot.Payments.Webhooks.CustomerHandler,
    Tymeslot.Payments.Webhooks.SubscriptionHandler,
    Tymeslot.Payments.Webhooks.SetupIntentHandler,
    Tymeslot.Payments.Webhooks.InvoiceHandler,
    Tymeslot.Payments.Webhooks.RefundHandler,
    Tymeslot.Payments.Webhooks.TrialWillEndHandler,
    Tymeslot.Payments.Webhooks.DisputeHandler
  ]

  # Map of handler modules to their supported event types
  @event_types %{
    Tymeslot.Payments.Webhooks.CheckoutSessionHandler => ["checkout.session.completed"],
    Tymeslot.Payments.Webhooks.CheckoutSessionExpiredHandler => ["checkout.session.expired"],
    Tymeslot.Payments.Webhooks.ChargeHandler => ["charge.succeeded", "charge.failed"],
    Tymeslot.Payments.Webhooks.PaymentMethodHandler => ["payment_method.attached"],
    Tymeslot.Payments.Webhooks.PaymentIntentHandler => [
      "payment_intent.succeeded",
      "payment_intent.created"
    ],
    Tymeslot.Payments.Webhooks.CustomerHandler => ["customer.created", "customer.updated"],
    Tymeslot.Payments.Webhooks.SubscriptionHandler => [
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted"
    ],
    Tymeslot.Payments.Webhooks.SetupIntentHandler => [
      "setup_intent.created",
      "setup_intent.succeeded"
    ],
    Tymeslot.Payments.Webhooks.InvoiceHandler => [
      "invoice.created",
      "invoice.finalized",
      "invoice.paid",
      "invoice.payment_succeeded",
      "invoice.payment_failed",
      "invoice.upcoming"
    ],
    Tymeslot.Payments.Webhooks.RefundHandler => [
      "charge.refunded",
      "charge.refund.updated"
    ],
    Tymeslot.Payments.Webhooks.TrialWillEndHandler => [
      "customer.subscription.trial_will_end"
    ],
    Tymeslot.Payments.Webhooks.DisputeHandler => [
      "charge.dispute.created",
      "charge.dispute.updated",
      "charge.dispute.closed"
    ]
  }

  # Event types we deliberately receive but take no action on. Connect
  # application-fee events fire on the platform account for every paid booking
  # (the platform fee being collected or returned); they are expected and
  # benign, so we acknowledge them silently rather than raising an
  # unhandled-event admin alert for each one.
  @ignored_event_types [
    "application_fee.created",
    "application_fee.refunded"
  ]

  @doc """
  Finds a handler for the given event type.

  Uses the @event_types map for O(1) lookup efficiency.

  Returns {:ok, handler_module} if a handler is found,
  or {:error, :no_handler} if no handler exists for the event type.
  """
  @spec find_handler(String.t()) :: {:ok, module()} | {:error, :no_handler}
  def find_handler(event_type) do
    handler =
      Enum.find_value(@event_types, fn {module, event_types} ->
        if event_type in event_types, do: module, else: nil
      end)

    case handler do
      nil -> {:error, :no_handler}
      module -> {:ok, module}
    end
  end

  @doc """
  Returns true for event types we intentionally receive but do not handle,
  and which should not trigger an unhandled-event admin alert.
  """
  @spec ignored?(String.t()) :: boolean()
  def ignored?(event_type), do: event_type in @ignored_event_types

  @doc """
  Returns a list of all event types handled by registered handlers.
  """
  @spec handled_event_types() :: [String.t()]
  def handled_event_types do
    Enum.flat_map(@webhook_handlers, fn handler ->
      Map.get(@event_types, handler, [])
    end)
  end

  @doc """
  Validates an object using the appropriate handler.

  Returns :ok if valid, or {:error, reason, message} if validation fails.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, atom(), String.t()}
  def validate(event_type, object) do
    with {:ok, handler} <- find_handler(event_type),
         :ok <- handler.validate(event_type, object) do
      :ok
    else
      {:error, reason, message} -> {:error, reason, message}
      # No validation if no handler
      {:error, :no_handler} -> :ok
    end
  end
end
