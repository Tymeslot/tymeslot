defmodule Tymeslot.Payments.Webhooks.RefundCascadeTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Tymeslot.Factory

  alias Swoosh.Email
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.Webhooks.RefundHandler

  defmodule RevocationManager do
    @spec update_subscription_status(String.t(), String.t(), DateTime.t()) :: {:ok, map()}
    def update_subscription_status(stripe_customer_id, status, at) do
      send(self(), {:revoked, stripe_customer_id, status, at})
      {:ok, %{stripe_customer_id: stripe_customer_id, status: status, canceled_at: at}}
    end
  end

  defmodule FailingManager do
    @spec update_subscription_status(String.t(), String.t(), DateTime.t()) :: {:error, term()}
    def update_subscription_status(_customer_id, _status, _at) do
      {:error, :downstream_unavailable}
    end
  end

  defmodule CapturingTemplate do
    @spec refund_processed_email(map(), integer(), String.t(), boolean()) :: Swoosh.Email.t()
    def refund_processed_email(user, refund_amount_cents, currency, revoked?) do
      send(self(), {:refund_email, user.id, refund_amount_cents, currency, revoked?})

      Email.new(
        to: user.email,
        from: "test@tymeslot.app",
        subject: "test",
        text_body: "test"
      )
    end
  end

  setup do
    original_schema = Application.get_env(:tymeslot, :subscription_schema)
    original_manager = Application.get_env(:tymeslot, :subscription_manager)
    original_repo = Application.get_env(:tymeslot, :repo)
    original_template = Application.get_env(:tymeslot, :refund_processed_template)

    Application.put_env(:tymeslot, :refund_processed_template, CapturingTemplate)

    on_exit(fn -> restore(:refund_processed_template, original_template) end)

    # The test env defaults :repo to Tymeslot.SaasRepo. Subscription lookups in
    # this test live in Tymeslot.Repo (where the factory inserts), so point both
    # the payments config and the email-delivery helper at Tymeslot.Repo.
    Application.put_env(:tymeslot, :repo, Tymeslot.Repo)
    Application.put_env(:tymeslot, :subscription_schema, PaymentTransactionSchema)

    on_exit(fn ->
      restore(:subscription_schema, original_schema)
      restore(:subscription_manager, original_manager)
      restore(:repo, original_repo)
    end)

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "payment_events:tymeslot")
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore(key, value), do: Application.put_env(:tymeslot, key, value)

  defp linked_subscription(opts \\ []) do
    user = insert(:user)

    customer_id = Keyword.get(opts, :customer_id, "cus_#{System.unique_integer([:positive])}")

    insert(:payment_transaction,
      user: user,
      status: "completed",
      stripe_customer_id: customer_id
    )

    {user, customer_id}
  end

  defp refunded_charge(customer_id, refunded_cents, charge_cents) do
    %{
      "id" => "ch_test_#{System.unique_integer([:positive])}",
      "customer" => customer_id,
      "amount" => charge_cents,
      "amount_refunded" => refunded_cents,
      "currency" => "eur"
    }
  end

  defp refunded_event(id \\ nil) do
    %{"id" => id || "evt_#{System.unique_integer([:positive])}", "type" => "charge.refunded"}
  end

  describe "process/2 — charge.refunded" do
    test "full refund revokes subscription access and notifies the user" do
      Application.put_env(:tymeslot, :subscription_manager, RevocationManager)
      {user, customer_id} = linked_subscription()
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "user:#{user.id}")

      charge = refunded_charge(customer_id, 10_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_processed} = RefundHandler.process(event, charge)

      # Revocation called with the right arguments
      assert_received {:revoked, ^customer_id, "canceled", %DateTime{}}

      # User-channel broadcast announces access revoked
      assert_received {:refund_processed, %{event_id: _, access_revoked: true}}

      # Global payment event also fired, carrying the revocation decision so
      # the SaaS consumer doesn't have to re-derive (or skip) it
      assert_received %{
        event: :charge_refunded,
        data: %{
          customer_id: ^customer_id,
          total_refunded: 10_000,
          charge_amount: 10_000,
          refund_percentage: 100.0,
          should_revoke: true
        }
      }

      user_id = user.id
      # Email quotes this refund's amount and says access was revoked
      assert_received {:refund_email, ^user_id, 10_000, "eur", true}
    end

    test "partial refund below threshold does NOT revoke access but still notifies" do
      Application.put_env(:tymeslot, :subscription_manager, RevocationManager)
      {user, customer_id} = linked_subscription()
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "user:#{user.id}")

      # 50% refund — below the default 90% threshold
      charge = refunded_charge(customer_id, 5_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_processed} = RefundHandler.process(event, charge)

      refute_received {:revoked, _customer, _status, _at}

      assert_received {:refund_processed, %{event_id: _, access_revoked: false}}

      assert_received %{
        event: :charge_refunded,
        data: %{customer_id: ^customer_id, should_revoke: false}
      }

      user_id = user.id
      # Email is sent without revocation copy, quoting this refund's amount
      assert_received {:refund_email, ^user_id, 5_000, "eur", false}
    end

    test "refund without a linked subscription is logged and does not broadcast on user channel" do
      Application.put_env(:tymeslot, :subscription_manager, RevocationManager)

      # No matching subscription exists in the DB
      charge = refunded_charge("cus_orphan", 10_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_logged} = RefundHandler.process(event, charge)

      refute_received {:revoked, _customer, _status, _at}

      # Global event still fires for the orphan refund
      assert_received %{
        event: :charge_refunded,
        data: %{customer_id: "cus_orphan", total_refunded: 10_000}
      }
    end

    test "refund proceeds when SubscriptionManager is unavailable (Standalone mode)" do
      # Test env configures a Mox mock by default — unset it to simulate Standalone.
      Application.delete_env(:tymeslot, :subscription_manager)
      {user, customer_id} = linked_subscription()
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "user:#{user.id}")

      charge = refunded_charge(customer_id, 10_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_processed} = RefundHandler.process(event, charge)

      # Broadcast still fires — but no manager call happened
      assert_received {:refund_processed, %{access_revoked: true}}
      refute_received {:revoked, _customer, _status, _at}
    end

    test "manager error returns retry_later and skips broadcast" do
      Application.put_env(:tymeslot, :subscription_manager, FailingManager)
      {user, customer_id} = linked_subscription()
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "user:#{user.id}")

      charge = refunded_charge(customer_id, 10_000, 10_000)
      event = refunded_event()

      assert {:error, :retry_later, _reason} = RefundHandler.process(event, charge)

      refute_received {:refund_processed, _payload}
    end
  end

  describe "process/2 — charge.refund.updated" do
    test "acknowledges status changes without side effects" do
      refund = %{"id" => "re_123", "status" => "succeeded"}
      event = %{"id" => "evt_456", "type" => "charge.refund.updated"}

      assert {:ok, :refund_status_updated} = RefundHandler.process(event, refund)

      refute_received {:refund_processed, _payload}
      refute_received {:revoked, _customer, _status, _at}
    end
  end
end
