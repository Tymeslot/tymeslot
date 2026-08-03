defmodule Tymeslot.Payments.Stripe do
  @moduledoc """
  Handles Stripe-specific payment operations for the Tymeslot application.
  Provides a clean interface for creating customers, sessions, and verifying payments.
  """
  @behaviour Tymeslot.Payments.Behaviours.StripeProvider

  require Logger

  alias Ecto.UUID
  alias Stripe.{BillingPortal, Checkout.Session, Customer, Subscription, Webhook}
  alias Tymeslot.Payments.Behaviours.StripeProvider
  alias Tymeslot.Payments.RetryHelper

  @type stripe_result :: {:ok, map()} | {:error, any()}

  # Module indirection for testability
  defp customer_mod, do: Application.get_env(:tymeslot, :stripe_customer_mod, Customer)
  defp session_mod, do: Application.get_env(:tymeslot, :stripe_session_mod, Session)

  defp subscription_mod,
    do: Application.get_env(:tymeslot, :stripe_subscription_mod, Subscription)

  defp webhook_mod, do: Application.get_env(:tymeslot, :stripe_webhook_mod, Webhook)

  defp charge_mod, do: Application.get_env(:tymeslot, :stripe_charge_mod, Stripe.Charge)

  @doc """
  Creates a Stripe customer for the given email.
  """
  @impl StripeProvider
  @spec create_customer(String.t()) :: stripe_result()
  def create_customer(email) when is_binary(email) do
    create_customer(%{email: email})
  end

  @spec create_customer(map()) :: stripe_result()
  def create_customer(params) when is_map(params) do
    email = params.email
    Logger.info("Creating Stripe customer", email: email)

    customer_params =
      Map.merge(
        %{
          email: email,
          metadata: Map.get(params, :metadata, %{"is_business" => "pending"})
        },
        Map.take(params, [:name, :phone, :address])
      )

    idempotency_key = generate_idempotency_key("customer_create", email)

    RetryHelper.execute_with_retry(fn ->
      customer_mod().create(customer_params, api_key_opts(idempotency_key))
    end)
  end

  # Private functions

  defp api_key_opts(idempotency_key \\ nil) do
    case stripe_api_key() do
      nil ->
        throw({:error, :missing_api_key})

      key ->
        base_opts = [api_key: key]

        if idempotency_key do
          Keyword.put(base_opts, :idempotency_key, idempotency_key)
        else
          base_opts
        end
    end
  end

  defp stripe_api_key do
    Application.get_env(:tymeslot, :stripe_secret_key) ||
      Application.get_env(:stripity_stripe, :api_key)
  end

  # Finds the subscription item to update
  # Can either use the subscription_item_id from opts or default to the first item
  defp find_subscription_item(subscription, opts) do
    items = Map.get(subscription, :items) || %{data: []}

    subscription_item =
      if item_id = Map.get(opts, :subscription_item_id) do
        Enum.find(items.data, fn item -> item.id == item_id end)
      else
        List.first(items.data)
      end

    if subscription_item do
      {:ok, subscription_item}
    else
      Logger.error("No subscription items found for subscription")
      {:error, :no_subscription_items}
    end
  end

  # Updates a subscription item with a new price
  defp update_subscription_item(subscription_id, subscription_item, new_price_id, idempotency_key) do
    subscription_mod().update(
      subscription_id,
      %{
        items: [
          %{
            id: subscription_item.id,
            price: new_price_id
          }
        ]
      },
      api_key_opts(idempotency_key)
    )
  end

  @doc false
  # Generates an idempotency key for Stripe API calls to prevent duplicate operations
  # Format: <operation>_<identifier>_<timestamp>
  defp generate_idempotency_key(operation, identifier) do
    # Hash the identifier to keep key length reasonable
    hashed_id =
      :crypto.hash(:sha256, to_string(identifier))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    # Include date (not full timestamp) to allow retries on different days if needed
    date = Date.utc_today() |> Date.to_string() |> String.replace("-", "")

    "#{operation}_#{hashed_id}_#{date}"
  end

  @doc """
  Expires a Stripe checkout session, preventing it from being completed.
  """
  @impl StripeProvider
  @spec expire_checkout_session(String.t()) :: stripe_result()
  def expire_checkout_session(session_id) when is_binary(session_id) do
    Logger.info("Expiring Stripe checkout session", session_id: session_id)

    RetryHelper.execute_with_retry(fn ->
      session_mod().expire(session_id, %{}, api_key_opts())
    end)
  end

  @doc """
  Creates a Stripe checkout session for subscription processing.
  """
  @impl StripeProvider
  @spec create_checkout_session_for_subscription(map()) :: stripe_result()
  def create_checkout_session_for_subscription(params) when is_map(params) do
    Logger.info("Creating Stripe subscription checkout session")

    request_id =
      params
      |> Map.get(:metadata, %{})
      |> Map.get("checkout_request_id", UUID.generate())

    idempotency_key = generate_idempotency_key("subscription_checkout", request_id)

    RetryHelper.execute_with_retry(fn ->
      session_mod().create(params, api_key_opts(idempotency_key))
    end)
  end

  @doc """
  Cancels a Stripe subscription.
  """
  @impl StripeProvider
  @spec cancel_subscription(String.t(), keyword()) :: stripe_result()
  def cancel_subscription(subscription_id, opts \\ []) when is_binary(subscription_id) do
    Logger.info("Canceling Stripe subscription", subscription_id: subscription_id)

    at_period_end = Keyword.get(opts, :at_period_end, true)

    params =
      if at_period_end do
        %{cancel_at_period_end: true}
      else
        %{}
      end

    operation = if at_period_end, do: "cancel_at_period_end", else: "cancel_now"
    idempotency_key = generate_idempotency_key("subscription_#{operation}", subscription_id)

    RetryHelper.execute_with_retry(fn ->
      if at_period_end do
        subscription_mod().update(subscription_id, params, api_key_opts(idempotency_key))
      else
        subscription_mod().cancel(subscription_id, %{}, api_key_opts(idempotency_key))
      end
    end)
  end

  @doc """
  Updates a Stripe subscription to a new price.
  """
  @impl StripeProvider
  @spec update_subscription(String.t(), String.t(), map()) :: stripe_result()
  def update_subscription(subscription_id, new_price_id, opts \\ %{})
      when is_binary(subscription_id) and is_binary(new_price_id) do
    Logger.info("Updating Stripe subscription",
      subscription_id: subscription_id,
      new_price_id: new_price_id
    )

    idempotency_key =
      generate_idempotency_key("subscription_update", "#{subscription_id}_#{new_price_id}")

    RetryHelper.execute_with_retry(fn ->
      with {:ok, subscription} <-
             subscription_mod().retrieve(subscription_id, %{}, api_key_opts()),
           {:ok, subscription_item} <- find_subscription_item(subscription, opts) do
        update_subscription_item(
          subscription_id,
          subscription_item,
          new_price_id,
          idempotency_key
        )
      end
    end)
  end

  @doc """
  Retrieves a Stripe subscription.
  """
  @impl StripeProvider
  @spec get_subscription(String.t()) :: stripe_result()
  def get_subscription(subscription_id) when is_binary(subscription_id) do
    Logger.info("Retrieving Stripe subscription", subscription_id: subscription_id)

    RetryHelper.execute_with_retry(fn ->
      subscription_mod().retrieve(subscription_id, %{}, api_key_opts())
    end)
  end

  @doc """
  Retrieves a Stripe charge.
  """
  @impl StripeProvider
  @spec get_charge(String.t()) :: stripe_result()
  def get_charge(charge_id) when is_binary(charge_id) do
    Logger.info("Retrieving Stripe charge", charge_id: charge_id)

    RetryHelper.execute_with_retry(fn ->
      charge_mod().retrieve(charge_id, %{}, api_key_opts())
    end)
  end

  @doc """
  Constructs and verifies a webhook event from Stripe.
  This is primarily used by the webhook signature verifier.
  """
  @impl StripeProvider
  @spec construct_webhook_event(binary(), String.t(), String.t()) :: stripe_result()
  def construct_webhook_event(payload, signature, secret)
      when is_binary(payload) and is_binary(signature) and is_binary(secret) do
    webhook_mod().construct_event(payload, signature, secret)
  end

  @doc """
  Lists subscriptions from Stripe with optional filters.
  """
  @impl StripeProvider
  @spec list_subscriptions(map()) :: stripe_result()
  def list_subscriptions(params \\ %{}) when is_map(params) do
    Logger.info("Listing Stripe subscriptions", params: inspect(params))

    RetryHelper.execute_with_retry(fn ->
      subscription_mod().list(params, api_key_opts())
    end)
  end

  @doc """
  Returns the Stripe webhook secret from configuration or environment.
  """
  @impl StripeProvider
  @spec webhook_secret() :: String.t() | nil
  def webhook_secret do
    Application.get_env(:stripity_stripe, :webhook_secret) ||
      Application.get_env(:tymeslot, :stripe_webhook_secret)
  end

  @doc """
  Creates a Stripe billing portal session for subscription management.
  """
  @impl StripeProvider
  @spec create_billing_portal_session(String.t(), String.t()) :: stripe_result()
  def create_billing_portal_session(customer_id, return_url)
      when is_binary(customer_id) and is_binary(return_url) do
    Logger.info("Creating Stripe billing portal session", customer_id: customer_id)

    RetryHelper.execute_with_retry(fn ->
      BillingPortal.Session.create(
        %{customer: customer_id, return_url: return_url},
        api_key_opts()
      )
    end)
  end
end
