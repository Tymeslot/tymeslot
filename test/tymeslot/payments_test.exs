defmodule Tymeslot.PaymentsTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils
  @moduletag :payments

  import Ecto.Query, only: [from: 2]
  import Mox, only: [verify_on_exit!: 1]

  alias Tymeslot.Factory
  alias Tymeslot.Payments
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.SubscriptionManagerMock
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  setup :verify_on_exit!

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
          status: :pending,
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

      assert updated_pending.status == :failed
      assert updated_pending.metadata["superseded"] == true
    end

    test "returns checkout url even if transaction update fails" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        status: :completed,
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

      assert %{status: :pending, stripe_id: nil} =
               Repo.get_by(PaymentTransactionSchema,
                 user_id: user.id,
                 status: :pending
               )
    end
  end

  describe "initiate_subscription/7 with a checkout session without a url" do
    setup do
      set_subscription_manager(SubscriptionManagerMock)

      Mox.stub(SubscriptionManagerMock, :create_subscription_checkout, fn _price,
                                                                          _prod,
                                                                          _amt,
                                                                          _uid,
                                                                          _email,
                                                                          _urls,
                                                                          _meta ->
        {:ok,
         StripeFixtures.without(StripeFixtures.object("checkout_session_subscription"), ["url"])}
      end)

      %{user: Factory.insert(:user)}
    end

    test "is an error, not a crash, and the session is expired", %{user: user} do
      StripeStub.expect(
        :expire_checkout_session,
        StripeFixtures.object("checkout_session_expired")
      )

      assert {:error, :missing_checkout_url} = initiate(user)

      assert %{status: :failed, metadata: %{"subscription_checkout_failed" => true}} =
               Repo.get_by(PaymentTransactionSchema, user_id: user.id)

      assert [%{method: :post, path: "/v1/checkout/sessions/cs_test1/expire"}] =
               StripeStub.requests()
    end

    test "is still an error when the session cannot be expired", %{user: user} do
      StripeStub.expect(:expire_checkout_session, {:error_fixture, "invalid_request_error"})

      assert {:error, :missing_checkout_url} = initiate(user)

      assert %{status: :failed} = Repo.get_by(PaymentTransactionSchema, user_id: user.id)
    end
  end

  # Two initiations by one user overlapping: B starts while A waits on Stripe
  # for its session. B runs inside A's stubbed call, at exactly that moment.
  describe "initiate_subscription/7 started again while a checkout is being prepared" do
    setup do
      set_subscription_manager(SubscriptionManagerMock)
      %{user: Factory.insert(:user)}
    end

    test "waits for the first checkout instead of starting a second", %{user: user} do
      expect_session("cs_A", fn ->
        assert {:error, :retry_later} = initiate(user)
      end)

      assert {:ok, %{checkout_url: "https://checkout.stripe.com/cs_A"}} = initiate(user)

      assert [%{stripe_id: "cs_A"}] = pending_transactions(user)
      assert StripeStub.requests() == []
    end

    test "expires the first checkout's session when a later one superseded it", %{user: user} do
      expect_session("cs_A", fn ->
        # A's Stripe calls have outlasted the cutoff, so B supersedes A's row.
        backdate_pending(user, 180)
        expect_session("cs_B", fn -> :ok end)

        assert {:ok, %{checkout_url: "https://checkout.stripe.com/cs_B"}} = initiate(user)
      end)

      StripeStub.expect(
        :expire_checkout_session,
        StripeFixtures.object("checkout_session_expired", %{"id" => "cs_A"})
      )

      assert {:error, :checkout_superseded} = initiate(user)

      assert [%{stripe_id: "cs_B"}] = pending_transactions(user)

      assert [%{method: :post, path: "/v1/checkout/sessions/cs_A/expire"}] =
               StripeStub.requests()
    end
  end

  defp expect_session(session_id, during_call) do
    Mox.expect(SubscriptionManagerMock, :create_subscription_checkout, fn _price,
                                                                          _prod,
                                                                          _amt,
                                                                          _uid,
                                                                          _email,
                                                                          _urls,
                                                                          _meta ->
      during_call.()

      {:ok,
       StripeFixtures.object("checkout_session_subscription", %{
         "id" => session_id,
         "url" => "https://checkout.stripe.com/#{session_id}"
       })}
    end)
  end

  defp pending_transactions(user) do
    Repo.all(
      from(t in PaymentTransactionSchema, where: t.user_id == ^user.id and t.status == :pending)
    )
  end

  defp backdate_pending(user, seconds) do
    Repo.update_all(
      from(t in PaymentTransactionSchema, where: t.user_id == ^user.id and t.status == :pending),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds)]
    )
  end

  defp initiate(user) do
    Payments.initiate_subscription(
      "price_123",
      "Pro Plan",
      1500,
      user.id,
      "test@example.com",
      %{success: "https://s", cancel: "https://c"}
    )
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
