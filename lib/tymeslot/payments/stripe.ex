defmodule Tymeslot.Payments.Stripe do
  @moduledoc """
  Handles Stripe-specific payment operations for the Tymeslot application.
  Provides a clean interface for creating customers, sessions, and verifying payments.
  """
  @behaviour Tymeslot.Payments.Behaviours.StripeProvider

  require Logger

  alias Ecto.UUID
  alias Stripe.{BillingPortal, Checkout.Session, Customer, Subscription, Webhook}
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

  @doc """
  Creates a Stripe checkout session for payment processing.
  """
  @spec create_session(map(), integer(), map(), String.t(), String.t()) :: stripe_result()
  def create_session(customer, amount, transaction, success_url, cancel_url)
      when is_integer(amount) do
    Logger.info("Creating Stripe session", customer_id: customer.id)

    session_params = build_session_params(customer, amount, transaction, success_url, cancel_url)
    idempotency_key = generate_idempotency_key("session_create", transaction.id)

    RetryHelper.execute_with_retry(fn ->
      session_mod().create(session_params, api_key_opts(idempotency_key))
    end)
  end

  @doc """
  Verifies a Stripe session by ID.
  """
  @spec verify_session(String.t()) :: stripe_result()
  def verify_session(session_id) when is_binary(session_id) do
    case session_mod().retrieve(session_id, %{}, api_key_opts()) do
      {:ok, session} ->
        Logger.info("Session verified successfully", session_id: session_id)
        {:ok, session}

      error ->
        Logger.error("Failed to verify session", error: inspect(error))
        error
    end
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

  defp build_session_params(customer, amount, transaction, success_url, cancel_url) do
    currency = Application.get_env(:tymeslot, :currency, "eur")

    %{
      mode: :payment,
      payment_method_types: [:card],
      line_items: [
        %{
          quantity: 1,
          price_data: %{
            currency: currency,
            unit_amount: amount,
            product_data: %{
              name: transaction.product_identifier || "Tymeslot Pro"
            }
          }
        }
      ],
      success_url: success_url,
      cancel_url: cancel_url,
      customer: customer.id,
      client_reference_id: to_string(transaction.id),
      tax_id_collection: %{enabled: true},
      billing_address_collection: :required,
      payment_intent_data: %{
        metadata: %{"transaction_id" => to_string(transaction.id)}
      },
      allow_promotion_codes: true,
      automatic_tax: %{enabled: true},
      customer_update: %{
        address: "auto",
        name: "auto",
        shipping: "auto"
      }
    }
  end

  @doc """
  Creates a Stripe checkout session for subscription processing.
  """
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
  @spec construct_webhook_event(binary(), String.t(), String.t()) :: stripe_result()
  def construct_webhook_event(payload, signature, secret)
      when is_binary(payload) and is_binary(signature) and is_binary(secret) do
    webhook_mod().construct_event(payload, signature, secret)
  end

  @doc """
  Lists subscriptions from Stripe with optional filters.
  """
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
  @spec webhook_secret() :: String.t() | nil
  def webhook_secret do
    Application.get_env(:stripity_stripe, :webhook_secret) ||
      Application.get_env(:tymeslot, :stripe_webhook_secret)
  end

  @doc """
  Creates a Stripe billing portal session for subscription management.
  """
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
