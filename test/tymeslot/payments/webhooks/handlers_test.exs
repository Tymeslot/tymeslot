defmodule Tymeslot.Payments.Webhooks.HandlersTest do
  # async: false: :subscription_manager is read through Payments.Config by every payment path,
  # not only by the webhook handlers under test here.
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.Webhooks.{
    CheckoutSessionExpiredHandler,
    CheckoutSessionHandler,
    WebhookRegistry
  }

  alias Tymeslot.Factory
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Repo

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp event(type, object), do: %{"type" => type, "data" => %{"object" => object}}

  describe "the registry" do
    test "routes each checkout session event to its own handler" do
      assert WebhookRegistry.handler_for("checkout.session.completed") == CheckoutSessionHandler

      assert WebhookRegistry.handler_for("checkout.session.expired") ==
               CheckoutSessionExpiredHandler
    end
  end

  describe "CheckoutSessionHandler" do
    test "handle/1 rejects a session without an id as permanent" do
      for object <- [%{}, %{"id" => ""}, nil] do
        assert {:error, :permanent, :missing_session_id} =
                 CheckoutSessionHandler.handle(event("checkout.session.completed", object))
      end
    end

    test "handle/1 ignores an unexpected (non-subscription) mode" do
      session = %{"id" => "cs_123", "mode" => "payment"}

      # The platform account only ever creates subscription-mode sessions;
      # paid bookings run through the separate Connect checkout and its own
      # webhook endpoint. Any other mode here is unexpected and must not be
      # silently treated as a processed payment.
      assert {:ok, :ignored} =
               CheckoutSessionHandler.handle(event("checkout.session.completed", session))
    end

    test "handle/1 handles subscription mode" do
      session = %{"id" => "cs_123", "mode" => "subscription"}

      # Mock subscription manager
      defmodule MockSubManager do
        @spec handle_checkout_completed(map()) :: {:ok, map()}
        def handle_checkout_completed(_session), do: {:ok, %{}}
      end

      Application.put_env(:tymeslot, :subscription_manager, MockSubManager)

      assert {:ok, :subscription_processed} =
               CheckoutSessionHandler.handle(event("checkout.session.completed", session))

      Application.delete_env(:tymeslot, :subscription_manager)
    end

    test "handle/1 returns error when subscription manager is missing" do
      session = %{"id" => "cs_123", "mode" => "subscription"}
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :permanent, :subscriptions_not_supported} =
               CheckoutSessionHandler.handle(event("checkout.session.completed", session))
    end
  end

  describe "CheckoutSessionExpiredHandler" do
    test "handle/1 rejects a session without an id as permanent" do
      for object <- [%{}, %{"id" => ""}, nil] do
        assert {:error, :permanent, :missing_session_id} =
                 CheckoutSessionExpiredHandler.handle(event("checkout.session.expired", object))
      end
    end

    test "handle/1 handles expired session" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        stripe_id: "cs_expired",
        status: "pending"
      )

      session = %{"id" => "cs_expired"}

      assert {:ok, :event_processed} =
               CheckoutSessionExpiredHandler.handle(event("checkout.session.expired", session))

      tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "cs_expired"
        )

      assert tx.status == "failed"
    end

    test "handle/1 handles expired session when transaction not found" do
      session = %{"id" => "cs_not_found"}
      # Handler returns :event_processed even when transaction is not found
      # (process_failed_payment returns {:ok, :transaction_not_found} which is treated as success)
      assert {:ok, :event_processed} =
               CheckoutSessionExpiredHandler.handle(event("checkout.session.expired", session))
    end
  end
end
