defmodule Tymeslot.PaymentsTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Factory
  alias Tymeslot.Payments
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Repo

  describe "initiate_subscription/7" do
    test "successfully initiates subscription" do
      user = Factory.insert(:user)

      defmodule MockSubManager do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_123",
             "url" => "https://stripe.com/sub_123",
             "subscription" => "sub_123",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManager)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_123"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "cs_sub_123"
        )

      assert tx.subscription_id == "sub_123"
    end

    test "supersedes pending one-time transaction before subscription" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: "sess_one_time",
          metadata: %{"payment_type" => "one_time"}
        )

      defmodule MockSubManagerForSupersede do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_supersede",
             "url" => "https://stripe.com/sub_supersede",
             "subscription" => "sub_supersede",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManagerForSupersede)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_supersede"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      updated_pending = Repo.get!(PaymentTransactionSchema, pending_tx.id)

      assert updated_pending.status == "failed"
      assert updated_pending.metadata["superseded"] == true
    end

    test "returns checkout url even if transaction update fails" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_id: "cs_sub_conflict"
      )

      defmodule MockSubManagerForUpdateFailure do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_conflict",
             "url" => "https://stripe.com/sub_conflict",
             "subscription" => "sub_conflict",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManagerForUpdateFailure)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_conflict"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      assert %{status: "pending", stripe_id: nil} =
               Repo.get_by(PaymentTransactionSchema,
                 user_id: user.id,
                 status: "pending"
               )
    end
  end

  defp set_subscription_manager(manager) do
    original = Application.get_env(:tymeslot, :subscription_manager)
    Application.put_env(:tymeslot, :subscription_manager, manager)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :subscription_manager)
      else
        Application.put_env(:tymeslot, :subscription_manager, original)
      end
    end)

    :ok
  end
end
