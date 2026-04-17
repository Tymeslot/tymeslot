defmodule Tymeslot.Payments.Webhooks.WebhookProcessor do
  @moduledoc """
  Processes Stripe webhook events using registered handlers.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Payments.Errors.WebhookError
  alias Tymeslot.Payments.Webhooks.WebhookRegistry

  @doc """
  Process a webhook event using the appropriate handler.
  """
  @spec process_event(map()) :: {:ok, atom()} | {:error, atom() | Exception.t(), String.t() | nil}
  def process_event(event) do
    if !is_map(event), do: raise(ArgumentError, "Event must be a map")

    event_type = get_field(event, :type)
    data = get_field(event, :data)

    map_transient_errors(do_process_data(data, event_type, event))
  rescue
    exception ->
      event_type = get_field(event, :type) || "unknown"

      map_transient_errors(handle_exception(exception, event_type, __STACKTRACE__))
  end

  defp map_transient_errors({:error, :retry_later, _message} = result), do: result

  defp map_transient_errors({:error, %Stripe.Error{source: :network} = err, message}) do
    {:error, :retry_later, message || "Stripe network error: #{err.message}"}
  end

  defp map_transient_errors(
         {:error, %WebhookError.ProcessingError{message: message} = err, stack}
       ) do
    # Check if this processing error was caused by a Stripe network error
    if message &&
         (String.contains?(message, "Stripe.Error") || String.contains?(message, "network")) do
      {:error, :retry_later, message}
    else
      {:error, err, stack}
    end
  end

  defp map_transient_errors(result), do: result

  defp do_process_data(nil, event_type, _event) do
    Logger.info("Processing minimal webhook event", event_type: event_type)

    case WebhookRegistry.find_handler(event_type) do
      {:ok, _handler} -> {:ok, :minimal_event_processed}
      {:error, :no_handler} -> {:ok, :unhandled_event}
    end
  end

  defp do_process_data(%{} = data_map, event_type, event) do
    object = get_field(data_map, :object)
    do_process_event(event_type, event, object)
  end

  defp do_process_data(_data, _event_type, _event) do
    {:error,
     %WebhookError.ProcessingError{
       reason: :invalid_input,
       message: "Event must be a map",
       event_type: "unknown"
     }, nil}
  end

  defp handle_exception(exception, event_type, stacktrace) do
    Logger.error("Error processing webhook event",
      event_type: event_type,
      error: inspect(exception),
      stacktrace: stacktrace
    )

    {:error,
     %WebhookError.ProcessingError{
       reason: :exception,
       message: "Unhandled exception: #{inspect(exception)}",
       event_type: event_type
     }, nil}
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_field(_map, _key), do: nil

  defp do_process_event(event_type, event, object) do
    Logger.info("Processing webhook event",
      event_type: event_type,
      object_id: get_field(object, "id")
    )

    # First validate the object
    with :ok <- WebhookRegistry.validate(event_type, object),
         {:ok, handler} <- WebhookRegistry.find_handler(event_type) do
      # If valid, process it
      process_with_handler(handler, event, object)
    else
      {:error, :no_handler} ->
        # Log details for unhandled events
        Logger.info("Received unhandled Stripe event",
          event_type: event_type,
          object_type: get_field(object, :object),
          object_keys: Map.keys(object),
          metadata: get_field(object, :metadata) || %{}
        )

        # Record unhandled event in database for monitoring
        record_unhandled_event(event_type, event, object)

        # Alert admin about unhandled event
        AdminAlerts.report(:unhandled_webhook,
          summary: "Unhandled Stripe webhook event type",
          context: sanitize_alert_payload(event, object)
        )

        {:ok, :unhandled_event}

      {:error, reason, message} ->
        # Validation failed
        Logger.error("Webhook validation error",
          event_type: event_type,
          reason: reason,
          message: message,
          object_keys: Map.keys(object),
          object_sample: object |> Map.take(["id", "object", "type"]) |> inspect()
        )

        {:error, %WebhookError.ValidationError{reason: reason, message: message}, nil}
    end
  end

  defp process_with_handler(handler, event, object) do
    # Ensure event map has :type as atom key for pattern matching in handlers
    event_type = get_field(event, :type)
    normalized_event = Map.put(event, :type, event_type)

    handler.process(normalized_event, object)
  rescue
    exception ->
      Logger.error("Handler error",
        error: inspect(exception),
        handler: handler,
        stacktrace: __STACKTRACE__
      )

      {:error,
       %WebhookError.ProcessingError{
         reason: :handler_exception,
         message: "Handler exception: #{inspect(exception)}",
         event_type: get_field(event, :type)
       }, nil}
  end

  defp clock do
    Application.get_env(:tymeslot, :clock, DateTime)
  end

  defp record_unhandled_event(event_type, event, object) do
    # We use a supervised task to record unhandled events asynchronously so
    # that the webhook response is never blocked and a crash inside the
    # recorder cannot take down the webhook handler process.
    case Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
           attrs = %{
             event_type: "stripe.#{event_type}",
             payload: %{
               "stripe_event" => event,
               "stripe_object" => object,
               "unhandled" => true
             },
             response_status: 200,
             response_body: "Unhandled event logged",
             delivered_at: clock().utc_now()
           }

           # We reuse WebhookQueries.create_delivery but note that since this is an
           # incoming Stripe webhook, it doesn't have a corresponding internal 'webhook_id'.
           # We set webhook_id to nil if the schema allows, or skip if it's strictly for outgoing.
           # Given the schema, webhook_id is required. We'll log it to Logger for now
           # unless we want to create a dedicated 'stripe_events' table.
           Logger.debug("Stripe event logged to system",
             event_type: event_type,
             details: attrs
           )
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start unhandled-event recorder task", reason: inspect(reason))
    end
  end

  defp sanitize_alert_payload(event, object) do
    %{
      event_id: get_field(event, :id),
      event_type: get_field(event, :type),
      event_created: get_field(event, :created),
      livemode: get_field(event, :livemode),
      object_id: get_field(object, :id),
      object_type: get_field(object, :object)
    }
  end
end
