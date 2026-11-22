defmodule Tymeslot.Payments.PlatformBilling do
  @moduledoc """
  The platform account's subscription billing calls that carry decisions of
  their own beyond the Stripe request: the parameters a new customer gets, and
  the idempotency key each call is sent under.

  Results are Stripe's objects as Stripe sent them (string-keyed maps), or
  `{:error, %Tymeslot.Integrations.Stripe.Error{}}`, or
  `{:error, :missing_api_key}`.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Integrations.Stripe.{CheckoutSessions, Client, Customers, Subscriptions}
  alias Tymeslot.Security.SecurityLogger

  @doc """
  Creates a Stripe customer for an email, or from a params map carrying
  `:email` and optionally `:metadata`, `:name`, `:phone` and `:address`.
  Without `:metadata` the customer is marked `is_business: pending`.
  """
  @spec create_customer(String.t() | map()) :: Client.result()
  def create_customer(email) when is_binary(email), do: create_customer(%{email: email})

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

    Customers.create(customer_params,
      idempotency_key: legacy_idempotency_key("customer_create", email)
    )
  end

  @doc """
  Creates a Checkout session in subscription mode, keyed on the
  `"checkout_request_id"` in its metadata, so a repeated request for the same
  checkout returns the same session.
  """
  @spec create_subscription_checkout(map()) :: Client.result()
  def create_subscription_checkout(params) when is_map(params) do
    Logger.info("Creating Stripe subscription checkout session")

    request_id =
      params
      |> Map.get(:metadata, %{})
      |> Map.get("checkout_request_id", UUID.generate())

    CheckoutSessions.create(params,
      idempotency_key: legacy_idempotency_key("subscription_checkout", request_id)
    )
  end

  @doc """
  Cancels a subscription at the end of its period (the default) or, with
  `at_period_end: false`, at once.

  A period-end cancel is keyed on the operation, subscription and day; a
  caller whose repeated cancels on the same day are each meant to reach Stripe
  passes its own `:idempotency_key`. A cancel now is a DELETE, which carries
  no key.
  """
  @spec cancel_subscription(String.t(), keyword()) :: Client.result()
  def cancel_subscription(subscription_id, opts) when is_binary(subscription_id) do
    Logger.info("Canceling Stripe subscription", subscription_id: subscription_id)

    if Keyword.get(opts, :at_period_end, true) do
      idempotency_key =
        Keyword.get_lazy(opts, :idempotency_key, fn ->
          legacy_idempotency_key("subscription_cancel_at_period_end", subscription_id)
        end)

      Subscriptions.update(subscription_id, %{cancel_at_period_end: true},
        idempotency_key: idempotency_key
      )
    else
      Subscriptions.cancel(subscription_id, %{}, [])
    end
  end

  # The day-scoped key these calls are sent under:
  # `<operation>_<first 16 hex of sha256(identifier)>_<YYYYMMDD>`. It is not
  # the intent key `Stripe.IdempotencyKey` formats for other calls; these
  # three keep this format until they move to intent keys, so both formats
  # are in use meanwhile.
  defp legacy_idempotency_key(operation, identifier) do
    digest = :sha256 |> :crypto.hash(to_string(identifier)) |> Base.encode16(case: :lower)

    Enum.join(
      [operation, binary_part(digest, 0, 16), Calendar.strftime(Date.utc_today(), "%Y%m%d")],
      "_"
    )
  end
end
