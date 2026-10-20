defmodule Tymeslot.Payments.Stripe do
  @moduledoc """
  Handles Stripe-specific payment operations for the Tymeslot application.
  Provides a clean interface for creating customers, sessions, and verifying payments.
  """
  @behaviour Tymeslot.Payments.Behaviours.StripeProvider

  require Logger

  alias Ecto.UUID
  alias Stripe.{BillingPortal, Checkout.Session, Customer, Subscription}
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Behaviours.StripeProvider
  alias Tymeslot.Payments.Config
  alias Tymeslot.Security.SecurityLogger

  @type stripe_result :: {:ok, map()} | {:error, any()}

  # Module indirection for testability
  defp customer_mod, do: Application.get_env(:tymeslot, :stripe_customer_mod, Customer)
  defp session_mod, do: Application.get_env(:tymeslot, :stripe_session_mod, Session)

  defp subscription_mod,
    do: Application.get_env(:tymeslot, :stripe_subscription_mod, Subscription)

  defp charge_mod, do: Application.get_env(:tymeslot, :stripe_charge_mod, Stripe.Charge)
  defp invoice_mod, do: Application.get_env(:tymeslot, :stripe_invoice_mod, Stripe.Invoice)

  defp invoice_payment_mod,
    do: Application.get_env(:tymeslot, :stripe_invoice_payment_mod, Stripe.InvoicePayment)

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
    Logger.info("Creating Stripe customer", email_masked: SecurityLogger.mask_email(email))

    customer_params =
      Map.merge(
        %{
          email: email,
          metadata: Map.get(params, :metadata, %{"is_business" => "pending"})
        },
        Map.take(params, [:name, :phone, :address])
      )

    idempotency_key = generate_idempotency_key("customer_create", email)

    with {:ok, opts} <- api_key_opts(idempotency_key),
         do: customer_mod().create(customer_params, opts)
  end

  # Private functions

  # Each call is made once: a failure goes back to the caller, whose own
  # retry (Stripe redelivering a webhook, Oban rerunning a job, a person
  # trying again) decides whether it is worth another attempt.
  defp api_key_opts(idempotency_key \\ nil) do
    case Config.stripe_api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        {:ok, Enum.reject([api_key: key, idempotency_key: idempotency_key], &is_nil(elem(&1, 1)))}
    end
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

    with {:ok, opts} <- api_key_opts(), do: session_mod().expire(session_id, %{}, opts)
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

    with {:ok, opts} <- api_key_opts(idempotency_key), do: session_mod().create(params, opts)
  end

  @doc """
  Cancels a Stripe subscription.

  The idempotency key defaults to one scoped to the operation, subscription and
  day. A caller whose repeated cancels on the same day are each meant to reach
  Stripe passes its own `:idempotency_key`.
  """
  @impl StripeProvider
  @spec cancel_subscription(String.t(), keyword()) :: stripe_result()
  def cancel_subscription(subscription_id, opts) when is_binary(subscription_id) do
    Logger.info("Canceling Stripe subscription", subscription_id: subscription_id)

    at_period_end = Keyword.get(opts, :at_period_end, true)

    params =
      if at_period_end do
        %{cancel_at_period_end: true}
      else
        %{}
      end

    operation = if at_period_end, do: "cancel_at_period_end", else: "cancel_now"

    idempotency_key =
      Keyword.get_lazy(opts, :idempotency_key, fn ->
        generate_idempotency_key("subscription_#{operation}", subscription_id)
      end)

    with {:ok, opts} <- api_key_opts(idempotency_key) do
      if at_period_end,
        do: subscription_mod().update(subscription_id, params, opts),
        else: subscription_mod().cancel(subscription_id, %{}, opts)
    end
  end

  @doc """
  Undoes a cancel-at-period-end, so the subscription renews again.

  Sent without an idempotency key: setting the flag to false is idempotent by
  itself, and a day-scoped key would make a second resume on the same day
  replay the first response without reaching Stripe.
  """
  @impl StripeProvider
  @spec resume_subscription(String.t()) :: stripe_result()
  def resume_subscription(subscription_id) when is_binary(subscription_id) do
    Logger.info("Resuming Stripe subscription", subscription_id: subscription_id)

    with {:ok, opts} <- api_key_opts(),
         do: subscription_mod().update(subscription_id, %{cancel_at_period_end: false}, opts)
  end

  @doc """
  Lists charges from Stripe, one page at a time, with Stripe's own filters
  (`customer`, `created`, `limit`, `starting_after`, `expand`). A charge's
  refunds come back only when expanded (`expand: ["data.refunds"]`).
  """
  @impl StripeProvider
  @spec list_charges(map()) :: stripe_result()
  def list_charges(params) when is_map(params) do
    Logger.info("Listing Stripe charges", params: LogFormat.reason(params))

    with {:ok, opts} <- api_key_opts(), do: charge_mod().list(params, opts)
  end

  @doc """
  Lists invoices from Stripe, one page at a time, with Stripe's own filters
  (`customer`, `subscription`, `status`, `created`, `limit`,
  `starting_after`).
  """
  @impl StripeProvider
  @spec list_invoices(map()) :: stripe_result()
  def list_invoices(params) when is_map(params) do
    Logger.info("Listing Stripe invoices", params: LogFormat.reason(params))

    with {:ok, opts} <- api_key_opts(), do: invoice_mod().list(params, opts)
  end

  @doc """
  Retrieves a Stripe invoice.
  """
  @impl StripeProvider
  @spec get_invoice(String.t()) :: stripe_result()
  def get_invoice(invoice_id) when is_binary(invoice_id) do
    Logger.info("Retrieving Stripe invoice", invoice_id: invoice_id)

    with {:ok, opts} <- api_key_opts(), do: invoice_mod().retrieve(invoice_id, %{}, opts)
  end

  @doc """
  Lists the payments made against invoices, one page at a time, with
  Stripe's own filters (`invoice`, `payment`, `status`, `limit`,
  `starting_after`). Filtering on `payment` finds the invoice a payment
  intent paid: `%{payment: %{type: "payment_intent", payment_intent: id}}`.
  """
  @impl StripeProvider
  @spec list_invoice_payments(map()) :: stripe_result()
  def list_invoice_payments(params) when is_map(params) do
    Logger.info("Listing Stripe invoice payments", params: LogFormat.reason(params))

    with {:ok, opts} <- api_key_opts(), do: invoice_payment_mod().list(params, opts)
  end

  @doc """
  Turns Stripe Tax's automatic calculation on or off for a subscription, from
  its next invoice on.

  Sent without an idempotency key: setting the flag is idempotent by itself.
  """
  @impl StripeProvider
  @spec update_subscription_automatic_tax(String.t(), boolean()) :: stripe_result()
  def update_subscription_automatic_tax(subscription_id, enabled)
      when is_binary(subscription_id) and is_boolean(enabled) do
    Logger.info("Updating Stripe subscription automatic tax",
      subscription_id: subscription_id,
      enabled: enabled
    )

    with {:ok, opts} <- api_key_opts(),
         do:
           subscription_mod().update(subscription_id, %{automatic_tax: %{enabled: enabled}}, opts)
  end

  @doc """
  Deletes a Stripe customer. Stripe keeps the customer's invoices and charges
  for its own records; the customer object and its stored details go.
  """
  @impl StripeProvider
  @spec delete_customer(String.t()) :: stripe_result()
  def delete_customer(customer_id) when is_binary(customer_id) do
    Logger.info("Deleting Stripe customer", customer_id: customer_id)

    with {:ok, opts} <- api_key_opts(), do: customer_mod().delete(customer_id, opts)
  end

  @doc """
  Retrieves a Stripe subscription.
  """
  @impl StripeProvider
  @spec get_subscription(String.t()) :: stripe_result()
  def get_subscription(subscription_id) when is_binary(subscription_id) do
    Logger.info("Retrieving Stripe subscription", subscription_id: subscription_id)

    with {:ok, opts} <- api_key_opts(),
         do: subscription_mod().retrieve(subscription_id, %{}, opts)
  end

  @doc """
  Retrieves a Stripe charge.
  """
  @impl StripeProvider
  @spec get_charge(String.t()) :: stripe_result()
  def get_charge(charge_id) when is_binary(charge_id) do
    Logger.info("Retrieving Stripe charge", charge_id: charge_id)

    with {:ok, opts} <- api_key_opts(), do: charge_mod().retrieve(charge_id, %{}, opts)
  end

  @doc """
  Lists subscriptions from Stripe with optional filters.
  """
  @impl StripeProvider
  @spec list_subscriptions(map()) :: stripe_result()
  def list_subscriptions(params) when is_map(params) do
    Logger.info("Listing Stripe subscriptions", params: LogFormat.reason(params))

    with {:ok, opts} <- api_key_opts(), do: subscription_mod().list(params, opts)
  end

  @doc """
  Creates a Stripe billing portal session for subscription management.
  """
  @impl StripeProvider
  @spec create_billing_portal_session(String.t(), String.t()) :: stripe_result()
  def create_billing_portal_session(customer_id, return_url)
      when is_binary(customer_id) and is_binary(return_url) do
    Logger.info("Creating Stripe billing portal session", customer_id: customer_id)

    with {:ok, opts} <- api_key_opts(),
         do: BillingPortal.Session.create(%{customer: customer_id, return_url: return_url}, opts)
  end
end
