defmodule Tymeslot.Payments.SubscriptionFlow do
  @moduledoc false

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Payments.PaymentQueries

  alias Tymeslot.Payments.{
    ChangesetHelpers,
    Config,
    DatabaseOperations,
    PendingTransactions,
    Preflight
  }

  @spec initiate_subscription(
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t(),
          %{success: String.t(), cancel: String.t()},
          map()
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
    manager = subscription_manager()

    system_metadata = %{
      user_id: user_id,
      product_identifier: product_identifier,
      payment_type: "subscription",
      checkout_request_id: UUID.generate()
    }

    with {:ok, subscription_metadata} <-
           Preflight.sanitize_initiation(amount, user_id, metadata, system_metadata) do
      handle_subscription_initiation(
        manager,
        stripe_price_id,
        product_identifier,
        amount,
        user_id,
        email,
        urls,
        subscription_metadata
      )
    end
  end

  defp handle_subscription_initiation(
         manager,
         stripe_price_id,
         product_identifier,
         amount,
         user_id,
         email,
         urls,
         subscription_metadata
       ) do
    if manager do
      with :ok <- PendingTransactions.supersede_pending_transaction_if_needed(user_id),
           {:ok, transaction} <-
             create_pending_subscription_transaction(
               user_id,
               amount,
               product_identifier,
               subscription_metadata
             ) do
        process_subscription_checkout(
          manager,
          transaction,
          %{
            stripe_price_id: stripe_price_id,
            product_identifier: product_identifier,
            amount: amount,
            user_id: user_id,
            email: email,
            urls: urls
          },
          subscription_metadata
        )
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          handle_initiation_changeset_error(changeset, user_id, amount, product_identifier)

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.error("Subscription manager not configured")
      {:error, :subscriptions_not_supported}
    end
  end

  defp process_subscription_checkout(
         manager,
         transaction,
         params,
         subscription_metadata
       ) do
    %{
      stripe_price_id: stripe_price_id,
      product_identifier: product_identifier,
      amount: amount,
      user_id: user_id,
      email: email,
      urls: urls
    } = params

    case manager.create_subscription_checkout(
           stripe_price_id,
           product_identifier,
           amount,
           user_id,
           email,
           urls,
           subscription_metadata
         ) do
      {:ok, checkout_session} ->
        checkout_url = Map.get(checkout_session, "url") || checkout_session.url

        case update_subscription_transaction_from_checkout(transaction, checkout_session) do
          {:ok, _updated_transaction} ->
            {:ok, %{checkout_url: checkout_url}}

          {:error, reason} ->
            Logger.error(
              "Failed to persist subscription checkout session, returning URL anyway",
              error: inspect(reason)
            )

            {:ok, %{checkout_url: checkout_url}}
        end

      {:error, reason} ->
        _mark_result = mark_pending_subscription_transaction_failed(transaction, reason)
        {:error, reason}
    end
  end

  defp create_pending_subscription_transaction(
         user_id,
         amount,
         product_identifier,
         subscription_metadata
       ) do
    transaction_attrs = %{
      user_id: user_id,
      amount: amount,
      product_identifier: product_identifier,
      status: "pending",
      metadata: subscription_metadata
    }

    DatabaseOperations.create_payment_transaction(transaction_attrs)
  end

  defp update_subscription_transaction_from_checkout(transaction, checkout_session) do
    checkout_session_id = Map.get(checkout_session, "id") || Map.get(checkout_session, :id)

    checkout_subscription_id =
      Map.get(checkout_session, "subscription") || Map.get(checkout_session, :subscription)

    checkout_url = Map.get(checkout_session, "url") || Map.get(checkout_session, :url)

    stripe_customer_id =
      Map.get(checkout_session, "customer") || Map.get(checkout_session, :customer)

    if is_nil(checkout_session_id) or is_nil(checkout_url) do
      {:error, :invalid_checkout_session}
    else
      attrs = %{
        stripe_id: checkout_session_id,
        subscription_id: checkout_subscription_id,
        stripe_customer_id: stripe_customer_id,
        metadata:
          Map.merge(transaction.metadata, %{
            "checkout_session" => checkout_session_id,
            "checkout_url" => checkout_url
          })
      }

      PaymentQueries.update_transaction(transaction, attrs)
    end
  end

  defp mark_pending_subscription_transaction_failed(transaction, reason) do
    failure_metadata = %{
      "subscription_checkout_failed" => true,
      "failure_reason" => inspect(reason),
      "failed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    update_attrs = %{
      status: "failed",
      metadata: Map.merge(transaction.metadata, failure_metadata)
    }

    case PaymentQueries.update_transaction(transaction, update_attrs) do
      {:ok, _updated} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to mark subscription transaction as failed", error: inspect(error))
        {:error, :transaction_update_failed}
    end
  end

  defp handle_initiation_changeset_error(changeset, user_id, amount, product_identifier) do
    if ChangesetHelpers.unique_pending_transaction_error?(changeset) do
      case pending_subscription_checkout_url_with_retry(user_id, amount, product_identifier) do
        {:ok, checkout_url} ->
          Logger.info("Returning existing subscription checkout URL", user_id: user_id)
          {:ok, %{checkout_url: checkout_url}}

        {:error, :checkout_conflict} ->
          {:error, :checkout_conflict}

        {:error, :retry_later} ->
          {:error, :retry_later}
      end
    else
      {:error, :transaction_creation_failed}
    end
  end

  defp pending_subscription_checkout_url_for_request(user_id, amount, product_identifier) do
    case PaymentQueries.get_pending_subscription_transaction(user_id) do
      {:ok, transaction} ->
        if transaction.amount == amount and transaction.product_identifier == product_identifier do
          {:ok, Map.get(transaction.metadata, "checkout_url")}
        else
          {:error, :checkout_conflict}
        end

      {:error, _reason} ->
        {:error, :retry_later}
    end
  end

  defp pending_subscription_checkout_url_with_retry(
         user_id,
         amount,
         product_identifier,
         attempts \\ 3,
         sleep_ms \\ 100
       )

  defp pending_subscription_checkout_url_with_retry(
         _user_id,
         _amount,
         _product_identifier,
         0,
         _sleep_ms
       ),
       do: {:error, :retry_later}

  defp pending_subscription_checkout_url_with_retry(
         user_id,
         amount,
         product_identifier,
         attempts,
         sleep_ms
       ) do
    case pending_subscription_checkout_url_for_request(user_id, amount, product_identifier) do
      {:ok, nil} ->
        Process.sleep(sleep_ms)

        pending_subscription_checkout_url_with_retry(
          user_id,
          amount,
          product_identifier,
          attempts - 1,
          sleep_ms
        )

      {:ok, checkout_url} ->
        {:ok, checkout_url}

      {:error, :checkout_conflict} ->
        {:error, :checkout_conflict}

      {:error, _reason} ->
        {:error, :retry_later}
    end
  end

  defp subscription_manager do
    Config.subscription_manager()
  end
end
