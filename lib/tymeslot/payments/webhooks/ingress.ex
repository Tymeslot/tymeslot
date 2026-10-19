defmodule Tymeslot.Payments.Webhooks.Ingress do
  @moduledoc """
  The one way a Stripe webhook delivery enters the application, for both
  endpoints:

    * `:platform` (`/webhooks/stripe`): subscription, invoice, refund and
      dispute events of the platform account, signed with
      `STRIPE_WEBHOOK_SECRET`.
    * `:connect` (`/webhooks/stripe/connect`): booking-payment events of
      the hosts' connected accounts, signed with
      `STRIPE_CONNECT_WEBHOOK_SECRET`.

  Each delivery is verified against its endpoint's secret, identified by its
  event id, run at most once under `Tymeslot.Payments.Webhooks.Idempotency`
  and dispatched to the handler its endpoint's registry names. Every handler
  implements `Tymeslot.Payments.Behaviours.WebhookHandler`, so both endpoints
  share one retry rule: only an explicit `{:error, :permanent, _}` is
  acknowledged as a failure, and everything else that does not succeed,
  a raised exception included, is handed back to Stripe to redeliver.

  The endpoints differ only in data:

    * the registry (`Tymeslot.Payments.Webhooks.WebhookRegistry` or
      `Tymeslot.MeetingPayments.Webhooks.WebhookRegistry`);
    * whether the processed event's payload is kept for debugging (platform
      only: Connect events carry attendee details);
    * what an unregistered event type does: the platform endpoint raises an
      admin alert, since every type it should receive is either registered
      or listed as deliberately ignored; the Connect endpoint logs it.

  Rejection details are logged here and never returned, so a caller has
  nothing to echo back to an unauthenticated sender.
  """

  require Logger

  alias Stripe.Webhook
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Webhooks.WebhookRegistry, as: ConnectRegistry
  alias Tymeslot.Payments.Webhooks.Idempotency
  alias Tymeslot.Payments.Webhooks.WebhookRegistry, as: PlatformRegistry

  @type endpoint :: :platform | :connect

  @type result ::
          Idempotency.result()
          | {:error, :not_configured | :invalid_signature | :invalid_payload}

  @endpoints %{
    platform: %{
      registry: PlatformRegistry,
      secret_key: :stripe_webhook_secret,
      store_payload?: true,
      alert_unhandled?: true
    },
    connect: %{
      registry: ConnectRegistry,
      secret_key: :stripe_connect_webhook_secret,
      store_payload?: false,
      alert_unhandled?: false
    }
  }

  @doc """
  Verifies and processes one delivery to `endpoint`.

  `signature` is the `Stripe-Signature` header, or `nil` when absent.
  Returns an `t:Idempotency.result/0` for a verified event, otherwise
  `{:error, :not_configured}` (the endpoint has no signing secret),
  `{:error, :invalid_signature}` or `{:error, :invalid_payload}` (a correctly
  signed body that is not a JSON object, or an event without an id).
  """
  @spec process(endpoint(), binary(), String.t() | nil) :: result()
  def process(endpoint, raw_body, signature)
      when is_map_key(@endpoints, endpoint) and is_binary(raw_body) do
    spec = Map.fetch!(@endpoints, endpoint)

    with {:ok, secret} <- fetch_secret(endpoint),
         {:ok, event} <- verify(endpoint, raw_body, signature, secret),
         {:ok, event_id, event_type} <- identify(endpoint, event) do
      Idempotency.with_idempotency(
        event_id,
        event_type,
        fn -> dispatch(spec, event_type, event) end,
        payload: if(spec.store_payload?, do: event)
      )
    end
  end

  @doc """
  The signing secret configured for `endpoint`, or `nil` when it is unset.
  """
  @spec signing_secret(endpoint()) :: String.t() | nil
  def signing_secret(endpoint) when is_map_key(@endpoints, endpoint) do
    case Application.get_env(:tymeslot, @endpoints[endpoint].secret_key) do
      secret when is_binary(secret) and secret != "" -> secret
      _unset -> nil
    end
  end

  defp fetch_secret(endpoint) do
    case signing_secret(endpoint) do
      nil ->
        Logger.error("Stripe webhook secret is not configured", endpoint: endpoint)
        {:error, :not_configured}

      secret ->
        {:ok, secret}
    end
  end

  # The event is decoded as Stripe sent it (`response_as: :map`) rather than
  # cast into the library's structs: an endpoint renders events at the API
  # version it was created with, not the one the library pins, and the
  # structs drop every field their own version lacks. A correctly signed
  # body that is not a JSON object is an invalid payload: the library
  # decodes only after the signature checks out, and raises if it cannot.
  defp verify(endpoint, raw_body, signature, secret) do
    case Webhook.construct_event(raw_body, signature || "", secret, response_as: :map) do
      {:ok, event} when is_map(event) -> {:ok, event}
      {:ok, _not_an_object} -> reject(endpoint, :not_an_object, :invalid_payload)
      {:error, reason} -> reject(endpoint, reason, :invalid_signature)
    end
  rescue
    exception in [Jason.DecodeError] ->
      reject(endpoint, exception.__struct__, :invalid_payload)
  end

  defp reject(endpoint, reason, result) do
    Logger.warning("Stripe webhook rejected",
      endpoint: endpoint,
      reason: LogFormat.reason(reason)
    )

    {:error, result}
  end

  defp identify(_endpoint, %{"id" => id} = event) when is_binary(id) and id != "",
    do: {:ok, id, Map.get(event, "type")}

  defp identify(endpoint, _event) do
    Logger.warning("Stripe webhook rejected: verified event carries no id", endpoint: endpoint)
    {:error, :invalid_payload}
  end

  defp dispatch(spec, event_type, %{"data" => %{"object" => object}} = event)
       when is_binary(event_type) and is_map(object) do
    case spec.registry.handler_for(event_type) do
      :ignore ->
        Logger.debug("Ignoring Stripe webhook event", event_type: event_type)
        {:ok, :ignored}

      nil ->
        unhandled(spec, event)

      handler ->
        Logger.info("Dispatching Stripe webhook event",
          event_type: event_type,
          event_id: event["id"]
        )

        run_handler(handler, event)
    end
  end

  defp dispatch(_spec, event_type, event) do
    Logger.warning("Stripe webhook event carries no object",
      event_type: event_type,
      event_id: event["id"]
    )

    {:error, :permanent, :invalid_event}
  end

  # Recorded by module alone: a handler's exception message can quote the
  # Stripe object it was processing, customer details included. The event's
  # type and id go into the context, and every attempt at the same event
  # fails at the same site, so redeliveries group as one error. An exit (a
  # GenServer call timing out, say) or a throw is retried the same way.
  defp run_handler(handler, event) do
    handler.handle(event)
  rescue
    exception -> handler_failed({:raised, exception.__struct__}, __STACKTRACE__, handler, event)
  catch
    :exit, _reason -> handler_failed(:exited, __STACKTRACE__, handler, event)
    :throw, _value -> handler_failed(:threw, __STACKTRACE__, handler, event)
  end

  defp handler_failed(reason, stacktrace, handler, event) do
    ErrorTracking.report_error(reason, stacktrace, %{
      handler: inspect(handler),
      event_type: event["type"],
      event_id: event["id"]
    })

    {:error, :retry_later, reason}
  end

  defp unhandled(%{alert_unhandled?: true}, event) do
    object = event["data"]["object"]

    Logger.info("Received unhandled Stripe event",
      event_type: event["type"],
      object_type: object["object"]
    )

    AdminAlerts.report(:unhandled_webhook,
      summary: "Unhandled Stripe webhook event type",
      context: %{
        event_id: event["id"],
        event_type: event["type"],
        event_created: event["created"],
        livemode: event["livemode"],
        object_id: object["id"],
        object_type: object["object"]
      }
    )

    {:ok, :unhandled_event}
  end

  defp unhandled(%{alert_unhandled?: false}, event) do
    Logger.info("Ignoring unhandled Stripe webhook event", event_type: event["type"])
    {:ok, :ignored}
  end
end
