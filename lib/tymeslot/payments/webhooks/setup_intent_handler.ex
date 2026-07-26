defmodule Tymeslot.Payments.Webhooks.SetupIntentHandler do
  @moduledoc """
  Handler for setup_intent.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) do
    event_type in ["setup_intent.created", "setup_intent.succeeded"]
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(setup_intent) do
    case Map.get(setup_intent, "id") do
      nil -> {:error, :missing_field, "Setup intent ID missing"}
      "" -> {:error, :missing_field, "Setup intent ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, setup_intent) do
    setup_intent_id = setup_intent["id"]

    Logger.info("Processing setup_intent event",
      event_type: event_type(event),
      setup_intent_id: setup_intent_id
    )

    {:ok, :setup_intent_processed}
  end

  # Stripe events arrive JSON-decoded, so string-keyed; the webhook processor
  # additionally stamps an atom `:type` before dispatching. Read both here, once.
  defp event_type(event), do: Map.get(event, "type") || Map.get(event, :type)
end
