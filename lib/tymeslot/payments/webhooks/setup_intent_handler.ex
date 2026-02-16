defmodule Tymeslot.Payments.Webhooks.SetupIntentHandler do
  @moduledoc """
  Handler for setup_intent.* webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

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
    event_type = event["type"] || event[:type]
    setup_intent_id = setup_intent["id"]

    Logger.info("Processing setup_intent event",
      event_type: event_type,
      setup_intent_id: setup_intent_id
    )

    {:ok, :setup_intent_processed}
  end
end
