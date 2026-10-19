defmodule Tymeslot.Payments.Webhooks.DisputeOutcomesTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Tymeslot.Test.PaymentEventCapture
  import Mox
  import Tymeslot.Factory

  alias Swoosh.Email
  alias Tymeslot.Payments.Webhooks.DisputeHandler

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    original_provider = Application.get_env(:tymeslot, :stripe_provider)
    original_manager = Application.get_env(:tymeslot, :subscription_manager)

    Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

    # Dispute routing for charges without invoice/subscription references
    # depends on a subscription manager being configured; pin it so earlier
    # suites that mutate the env cannot leak into these tests.
    Application.put_env(
      :tymeslot,
      :subscription_manager,
      Tymeslot.Payments.SubscriptionManagerMock
    )

    on_exit(fn ->
      restore(:stripe_provider, original_provider)
      restore(:subscription_manager, original_manager)
    end)

    capture_payment_events()
  end

  defp restore(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore(key, value), do: Application.put_env(:tymeslot, key, value)

  defp dispute(status, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "dp_#{System.unique_integer([:positive])}",
        "charge" => "ch_#{System.unique_integer([:positive])}",
        "amount" => 1000,
        "reason" => "fraudulent",
        "status" => status
      },
      attrs
    )
  end

  defp subscription_charge(customer_id \\ "cus_sub") do
    %{
      "id" => "ch_sub",
      "customer" => customer_id,
      "subscription" => "sub_123",
      "invoice" => "in_123"
    }
  end

  defp one_time_charge(customer_id) do
    %{"id" => "ch_one_time", "customer" => customer_id}
  end

  defp with_object(event, object), do: Map.put(event, "data", %{"object" => object})

  defmodule DisputeTemplate do
    @moduledoc false
    @spec dispute_won_notification(String.t(), map()) :: Swoosh.Email.t()
    def dispute_won_notification(address, _data),
      do: Email.new(to: address, subject: "Won", text_body: "Won.")
  end

  defmodule FailingHandler do
    @spec handle_payment_event(map()) :: {:error, term()}
    def handle_payment_event(_event), do: {:error, :enqueue_failed}
  end

  # A subscription dispute the handler could not take must fail the
  # delivery, so Stripe redelivers it rather than the dispute going
  # unrecorded.
  describe "handle/1 — a failed hand-off" do
    setup do
      Application.put_env(:tymeslot, :payment_event_handler, FailingHandler)
      stub(Tymeslot.Payments.StripeMock, :get_charge, fn _id -> {:ok, subscription_charge()} end)
      :ok
    end

    for {type, status} <- [
          {"charge.dispute.created", "needs_response"},
          {"charge.dispute.updated", "under_review"},
          {"charge.dispute.closed", "lost"}
        ] do
      test "#{type} returns retry_later" do
        event = %{"id" => "evt_fail_#{unquote(status)}", "type" => unquote(type)}

        # The hand-off's own failure, not the Stripe lookup's, which retries
        # the same way.
        assert {:error, :retry_later, {:hand_off_failed, :enqueue_failed}} =
                 DisputeHandler.handle(with_object(event, dispute(unquote(status))))
      end
    end
  end

  describe "handle/1 — charge.dispute.updated" do
    test "subscription dispute is handed off to the payment-event handler" do
      d = dispute("under_review")
      event = %{"id" => "evt_upd_1", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, subscription_charge()}
      end)

      assert {:ok, :dispute_updated} = DisputeHandler.handle(with_object(event, d))

      assert_received %{
        event: :dispute_updated,
        data: %{
          event_id: "evt_upd_1",
          stripe_dispute_id: _,
          status: "under_review"
        }
      }
    end

    test "a forwarded dispute carries the Stripe event's creation time" do
      event = %{
        "id" => "evt_upd_created",
        "created" => 1_700_000_456,
        "type" => "charge.dispute.updated"
      }

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, subscription_charge()}
      end)

      assert {:ok, :dispute_updated} =
               DisputeHandler.handle(with_object(event, dispute("under_review")))

      assert_received %{
        event: :dispute_updated,
        data: %{event_id: "evt_upd_created", event_created: 1_700_000_456}
      }
    end

    test "one-time charge dispute update does not broadcast" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_one_time"
      )

      d = dispute("under_review")
      event = %{"id" => "evt_upd_2", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_one_time")}
      end)

      assert {:ok, :dispute_updated} = DisputeHandler.handle(with_object(event, d))

      refute_received %{event: :dispute_updated, data: _}
    end

    test "subscription dispute without charge linkage fields is still forwarded" do
      # Stripe API 2025-03-31.basil removed invoice/subscription from the
      # charge. With a subscription manager configured, a customer without a
      # one-off transaction routes to the subscription listener.
      d = dispute("under_review")
      event = %{"id" => "evt_upd_4", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, %{"id" => "ch_sub_basil", "customer" => "cus_sub_basil"}}
      end)

      assert {:ok, :dispute_updated} = DisputeHandler.handle(with_object(event, d))

      assert_received %{
        event: :dispute_updated,
        data: %{event_id: "evt_upd_4", stripe_dispute_id: _, status: "under_review"}
      }
    end

    test "Stripe API error triggers retry_later" do
      d = dispute("under_review")
      event = %{"id" => "evt_upd_3", "type" => "charge.dispute.updated"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:error, %{message: "down"}}
      end)

      assert {:error, :retry_later, "Stripe API unavailable"} =
               DisputeHandler.handle(with_object(event, d))
    end
  end

  describe "handle/1 — charge.dispute.closed" do
    test "subscription dispute close is handed off to the payment-event handler" do
      d = dispute("won")
      event = %{"id" => "evt_close_1", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, subscription_charge()}
      end)

      assert {:ok, :dispute_closed} = DisputeHandler.handle(with_object(event, d))

      assert_received %{
        event: :dispute_closed,
        data: %{
          event_id: "evt_close_1",
          stripe_dispute_id: _,
          status: "won",
          dispute: _
        }
      }
    end

    test "one-time lost dispute fires admin alert and returns dispute_closed" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_lost_dispute"
      )

      d = dispute("lost", %{"amount" => 5000, "reason" => "duplicate"})
      event = %{"id" => "evt_close_2", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_lost_dispute")}
      end)

      assert {:ok, :dispute_closed} = DisputeHandler.handle(with_object(event, d))

      # No subscription broadcast for one-time charges
      refute_received %{event: :dispute_closed, data: _}
    end

    test "one-time won dispute returns dispute_closed without subscription broadcast" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_won_dispute"
      )

      d = dispute("won")
      event = %{"id" => "evt_close_3", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_won_dispute")}
      end)

      assert {:ok, :dispute_closed} = DisputeHandler.handle(with_object(event, d))
      refute_received %{event: :dispute_closed, data: _}
    end

    # The won notice goes out from a job, so an open mail circuit delays it
    # rather than dropping it. The job carries only what the notice shows:
    # the dispute's evidence (the customer's name and addresses) stays out of
    # the job table.
    test "one-time won dispute enqueues the won notice to the operator" do
      Application.put_env(:tymeslot, :dispute_alert_template, DisputeTemplate)
      Application.put_env(:tymeslot, :admin_alert_email, "ops@example.com")

      on_exit(fn ->
        Application.delete_env(:tymeslot, :dispute_alert_template)
        Application.delete_env(:tymeslot, :admin_alert_email)
      end)

      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_customer_id: "cus_won_notice"
      )

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_won_notice")}
      end)

      won =
        dispute("won", %{
          "id" => "dp_won_notice",
          "currency" => "eur",
          "evidence" => %{"customer_name" => "Jane Payer", "customer_email_address" => "j@x.test"},
          "evidence_details" => %{"due_by" => 1_767_225_600}
        })

      event = %{"id" => "evt_close_won_notice", "type" => "charge.dispute.closed"}
      assert {:ok, :dispute_closed} = DisputeHandler.handle(with_object(event, won))

      assert [
               %Oban.Job{
                 args: %{
                   "template_fun" => "dispute_won_notification",
                   "recipient" => recipient,
                   "template_args" => [data]
                 }
               }
             ] =
               Enum.filter(
                 Repo.all(Oban.Job),
                 &(&1.worker == "Tymeslot.Workers.SendConfiguredEmail")
               )

      assert recipient == %{"address" => "ops@example.com"}

      assert data == %{
               "stripe_dispute_id" => "dp_won_notice",
               "user_id" => user.id,
               "amount" => 1000,
               "currency" => "eur",
               "reason" => "fraudulent",
               "evidence_due_by" => "2026-01-01"
             }
    end

    test "Stripe API error triggers retry_later" do
      d = dispute("won")
      event = %{"id" => "evt_close_4", "type" => "charge.dispute.closed"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:error, %{message: "down"}}
      end)

      assert {:error, :retry_later, "Stripe API unavailable"} =
               DisputeHandler.handle(with_object(event, d))
    end
  end

  describe "handle/1 — charge.dispute.created (unlinked charge)" do
    test "unknown-customer dispute is forwarded when a subscription manager is configured" do
      d = dispute("needs_response")
      event = %{"id" => "evt_orphan", "type" => "charge.dispute.created"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_orphan_dispute")}
      end)

      # No payment_transaction exists for cus_orphan_dispute and the charge
      # carries no invoice/subscription reference; with a subscription manager
      # configured the dispute routes to the subscription listener.
      assert {:ok, :subscription_dispute_forwarded} = DisputeHandler.handle(with_object(event, d))
    end

    test "unknown-customer dispute stays on the local path in standalone mode" do
      original_manager = Application.get_env(:tymeslot, :subscription_manager)
      Application.put_env(:tymeslot, :subscription_manager, nil)
      on_exit(fn -> restore(:subscription_manager, original_manager) end)

      d = dispute("needs_response")
      event = %{"id" => "evt_orphan_standalone", "type" => "charge.dispute.created"}

      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:ok, one_time_charge("cus_orphan_standalone")}
      end)

      # Without a subscription manager there is nothing to forward to — the
      # handler logs the orphan dispute and alerts the admin instead.
      assert {:ok, :dispute_logged} = DisputeHandler.handle(with_object(event, d))
    end
  end
end
