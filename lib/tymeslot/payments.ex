defmodule Tymeslot.Payments do
  @moduledoc """
  Main entry point for payment operations.
  Provides a high-level interface for executing payment transactions.
  """

  require Logger

  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  alias Tymeslot.Payments.{
    ChargeInvoice,
    Config,
    CustomerLookup,
    DatabaseOperations,
    PaymentQueries,
    SubscriptionFlow,
    SubscriptionInvoice,
    SubscriptionInvoices
  }

  alias Tymeslot.Payments.Webhooks.Ingress

  @type transaction :: PaymentTransaction.t()
  @type stripe_id :: String.t()
  @type stripe_result :: {:ok, map()} | {:error, term()}

  @doc """
  Verifies and processes one Stripe webhook delivery to `endpoint`
  (`:platform` or `:connect`), reading that endpoint's signing secret from
  configuration. See `Tymeslot.Payments.Webhooks.Ingress.process/3` for the
  outcomes.
  """
  @spec process_webhook(Ingress.endpoint(), binary(), String.t() | nil) :: Ingress.result()
  defdelegate process_webhook(endpoint, raw_body, signature), to: Ingress, as: :process

  @doc """
  Processes a failed payment.

  ## Parameters
    * stripe_id - The Stripe session ID

  ## Returns
    * `{:ok, :payment_failed}` - If the payment failure is recorded successfully
    * `{:error, reason}` - If recording the payment failure fails
  """
  @spec process_failed_payment(stripe_id()) ::
          {:ok, :payment_failed | :transaction_not_found} | {:error, String.t()}
  def process_failed_payment(stripe_id) do
    Logger.info("Processing failed payment", stripe_id: stripe_id)
    DatabaseOperations.process_failed_payment(stripe_id)
  end

  @doc """
  The payments a user has made for platform subscriptions, oldest first, as
  `%{subscription_id, paid_at}`. See `SubscriptionInvoices.payments/1`.
  """
  @spec list_subscription_payments(pos_integer()) :: [
          %{subscription_id: String.t() | nil, paid_at: DateTime.t()}
        ]
  def list_subscription_payments(user_id), do: SubscriptionInvoices.payments(user_id)

  @doc """
  Lists a user's platform subscription invoices, newest first.

  Each entry carries the Stripe-hosted invoice page and PDF, so callers can
  link a customer straight to their VAT document instead of routing them
  through the billing portal. Covers subscription invoices only — Connect
  direct-charge booking invoices are not captured; see
  `SubscriptionInvoiceSchema`.

  ## Parameters
    * user_id - The ID of the user whose invoices to list
    * limit - Maximum number of invoices to return (defaults to
      `SubscriptionInvoiceQueries`'s default when omitted)
  """
  @spec list_subscription_invoices(pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id) do
    SubscriptionInvoices.list(user_id)
  end

  @spec list_subscription_invoices(pos_integer(), pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id, limit) do
    SubscriptionInvoices.list(user_id, limit)
  end

  @doc """
  Initiates a subscription with the provided payment details.

  This function creates a Stripe checkout session for recurring payments.
  The calling application is responsible for plan validation and providing
  the concrete payment details (stripe_price_id, amount, product_identifier).

  ## Parameters
    * stripe_price_id - The Stripe price ID for the subscription
    * product_identifier - Generic identifier for what is being purchased (plan name, etc.)
    * amount - The subscription amount in cents (for transaction tracking)
    * user_id - The ID of the user purchasing the subscription
    * email - The user's email address
    * success_url - URL to redirect to after successful subscription (required)
    * cancel_url - URL to redirect to if subscription is cancelled (required)
    * metadata - Additional metadata for the subscription (app-specific data)

  ## Returns
    * `{:ok, %{checkout_url: url}}` - URL for the Stripe checkout session
    * `{:error, reason}` - If the subscription creation fails
  """
  @spec initiate_subscription(
          stripe_price_id :: String.t(),
          product_identifier :: String.t(),
          amount :: pos_integer(),
          user_id :: pos_integer(),
          email :: String.t(),
          urls :: %{success: String.t(), cancel: String.t()},
          metadata :: map()
        ) :: {:ok, %{checkout_url: String.t()}} | {:error, term()}
  def initiate_subscription(
        stripe_price_id,
        product_identifier,
        amount,
        user_id,
        email,
        urls,
        metadata \\ %{}
      ) do
    SubscriptionFlow.initiate_subscription(
      stripe_price_id,
      product_identifier,
      amount,
      user_id,
      email,
      urls,
      metadata
    )
  end

  @doc """
  Reads a user id out of Stripe metadata, which carries it as a string.

  Returns `nil` for anything that is not a whole number, so a malformed or
  absent value never becomes a wrong user.
  """
  @spec parse_user_id(any()) :: integer() | nil
  defdelegate parse_user_id(id), to: CustomerLookup

  @doc """
  The invoice a platform charge paid and the subscription that invoice
  billed, read from Stripe where the charge and the recorded invoices do not
  say. Returns `{:error, reason}` when Stripe cannot be reached, so a caller
  acting on the answer retries rather than guessing. See
  `Tymeslot.Payments.ChargeInvoice`.
  """
  @spec charge_invoice(String.t()) :: {:ok, ChargeInvoice.t()} | {:error, term()}
  defdelegate charge_invoice(charge_id), to: ChargeInvoice, as: :for_charge_id

  @doc """
  As `charge_invoice/1`, for a charge the caller already holds (a webhook
  body or an API read), so the charge itself is not read again.
  """
  @spec invoice_for_charge(map()) :: {:ok, ChargeInvoice.t()} | {:error, term()}
  defdelegate invoice_for_charge(charge), to: ChargeInvoice, as: :for_charge

  @doc """
  Records a checkout session's outcome against its transaction row, attaching
  the subscription it produced.
  """
  @spec update_transaction_for_subscription(
          String.t(),
          String.t(),
          PaymentTransaction.status(),
          map()
        ) ::
          {:ok, transaction()} | {:error, term()}
  defdelegate update_transaction_for_subscription(
                checkout_session_id,
                subscription_id,
                status,
                metadata
              ),
              to: DatabaseOperations

  @doc """
  Lists every distinct Stripe customer id recorded on the user's payment
  transactions, including customers created by checkouts that were never
  completed.
  """
  @spec stripe_customer_ids_for_user(integer()) :: [String.t()]
  defdelegate stripe_customer_ids_for_user(user_id), to: PaymentQueries

  @doc """
  Checkouts left pending since before `:cutoff` (required) and not yet
  marked handled, counted per user as `{user_id, count}` tuples.

  Options:

    * `:cutoff` - the instant before which a pending transaction counts as
      abandoned. Pass the same value to `mark_abandoned_checkouts_handled/2`
      so the two cover the same transactions.
    * `:product_identifiers` - only transactions for these products.
    * `:payment_type` - only transactions whose metadata `payment_type`
      matches.
  """
  @spec list_abandoned_checkouts(keyword()) :: [{pos_integer(), pos_integer()}]
  defdelegate list_abandoned_checkouts(opts), to: PaymentQueries

  @doc """
  Marks the user's abandoned checkouts handled, so `list_abandoned_checkouts/1`
  stops returning them. Takes the same options; a checkout started after
  `:cutoff` is left alone. Returns the number of transactions marked.
  """
  @spec mark_abandoned_checkouts_handled(pos_integer(), keyword()) :: non_neg_integer()
  defdelegate mark_abandoned_checkouts_handled(user_id, opts), to: PaymentQueries

  @doc "Whether a Stripe platform API key is configured."
  @spec stripe_configured?() :: boolean()
  def stripe_configured?, do: is_binary(Config.stripe_api_key())

  # Stripe API. Each function calls the configured provider (resolved per
  # call, so a test's `:stripe_provider` override takes effect) and returns
  # its `{:ok, map()} | {:error, term()}` unchanged. Params and opts are those
  # of the matching `Tymeslot.Payments.Behaviours.StripeProvider` callback.

  @doc "Creates a Stripe customer from an email or a params map."
  @spec create_stripe_customer(String.t() | map()) :: stripe_result()
  def create_stripe_customer(email_or_params),
    do: Config.stripe_provider().create_customer(email_or_params)

  @doc "Deletes a Stripe customer."
  @spec delete_stripe_customer(String.t()) :: stripe_result()
  def delete_stripe_customer(customer_id),
    do: Config.stripe_provider().delete_customer(customer_id)

  @doc "Creates a Stripe Checkout session in subscription mode."
  @spec create_stripe_subscription_checkout(map()) :: stripe_result()
  def create_stripe_subscription_checkout(params),
    do: Config.stripe_provider().create_checkout_session_for_subscription(params)

  @doc "Creates a Stripe billing portal session returning to `return_url`."
  @spec create_stripe_billing_portal_session(String.t(), String.t()) :: stripe_result()
  def create_stripe_billing_portal_session(customer_id, return_url),
    do: Config.stripe_provider().create_billing_portal_session(customer_id, return_url)

  @doc "Reads a Stripe subscription."
  @spec get_stripe_subscription(String.t()) :: stripe_result()
  def get_stripe_subscription(subscription_id),
    do: Config.stripe_provider().get_subscription(subscription_id)

  @doc "Lists one page of Stripe subscriptions."
  @spec list_stripe_subscriptions(map()) :: stripe_result()
  def list_stripe_subscriptions(params),
    do: Config.stripe_provider().list_subscriptions(params)

  @doc "Cancels a Stripe subscription, now or at period end per `opts`."
  @spec cancel_stripe_subscription(String.t(), keyword()) :: stripe_result()
  def cancel_stripe_subscription(subscription_id, opts),
    do: Config.stripe_provider().cancel_subscription(subscription_id, opts)

  @doc "Withdraws a pending period-end cancellation of a Stripe subscription."
  @spec resume_stripe_subscription(String.t()) :: stripe_result()
  def resume_stripe_subscription(subscription_id),
    do: Config.stripe_provider().resume_subscription(subscription_id)

  @doc "Turns Stripe automatic tax on or off for a subscription."
  @spec set_stripe_subscription_automatic_tax(String.t(), boolean()) :: stripe_result()
  def set_stripe_subscription_automatic_tax(subscription_id, enabled),
    do: Config.stripe_provider().update_subscription_automatic_tax(subscription_id, enabled)

  @doc "Lists one page of Stripe invoices."
  @spec list_stripe_invoices(map()) :: stripe_result()
  def list_stripe_invoices(params), do: Config.stripe_provider().list_invoices(params)

  @doc "Lists one page of Stripe charges."
  @spec list_stripe_charges(map()) :: stripe_result()
  def list_stripe_charges(params), do: Config.stripe_provider().list_charges(params)

  @doc "Creates a Stripe refund; `opts` carries the `:idempotency_key`."
  @spec create_stripe_refund(map(), keyword()) :: stripe_result()
  def create_stripe_refund(params, opts), do: Config.stripe_provider().create_refund(params, opts)

  @doc """
  Whether `user_id`'s outgoing material carries the free-tier "Tymeslot"
  branding. Off unless the instance enables `:show_branding` and a
  subscription manager is configured to answer for the user; an unknown user
  never gets it, so a paying customer cannot be branded by a missing id.
  """
  @spec show_branding?(pos_integer() | nil) :: boolean()
  def show_branding?(user_id) when is_integer(user_id) do
    manager = Config.subscription_manager()

    Application.get_env(:tymeslot, :show_branding, false) == true and
      not is_nil(manager) and manager.should_show_branding?(user_id) == true
  end

  def show_branding?(_user_id), do: false
end
