defmodule Tymeslot.Payments.Webhooks.RefundCascadeTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Mox
  import Tymeslot.Test.PaymentEventCapture
  import Tymeslot.Factory

  alias Swoosh.Email
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.StripeMock
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionManagerMock
  alias Tymeslot.Payments.Webhooks.RefundHandler
  alias Tymeslot.Repo

  defmodule FailingHandler do
    @spec handle_payment_event(map()) :: {:error, term()}
    def handle_payment_event(_event), do: {:error, :downstream_unavailable}
  end

  defmodule CapturingTemplate do
    @spec refund_processed_email(map(), integer(), String.t(), String.t()) :: Swoosh.Email.t()
    def refund_processed_email(user, refund_amount_cents, currency, access) do
      send(self(), {:refund_email, user.id, refund_amount_cents, currency, access})

      Email.new(
        to: user.email,
        from: "test@tymeslot.app",
        subject: "test",
        text_body: "test"
      )
    end
  end

  setup :verify_on_exit!

  setup do
    original_manager = Application.get_env(:tymeslot, :subscription_manager)
    original_template = Application.get_env(:tymeslot, :refund_processed_template)
    original_handler = Application.get_env(:tymeslot, :payment_event_handler)

    Application.put_env(:tymeslot, :refund_processed_template, CapturingTemplate)

    on_exit(fn -> restore(:refund_processed_template, original_template) end)

    Application.put_env(:tymeslot, :subscription_manager, SubscriptionManagerMock)
    stub_lookups_over_transactions()

    # Current API versions send charge.refunded without the charge's refunds,
    # so the handler reads the latest one from Stripe. By default there is
    # none to read, and the email quotes the charge's refunded total.
    stub(StripeMock, :list_refunds, fn _params -> {:ok, %{data: [], has_more: false}} end)

    on_exit(fn ->
      restore(:subscription_manager, original_manager)
      restore(:payment_event_handler, original_handler)
    end)

    capture_payment_events()
  end

  # Payment transactions stand in for the subscription records a subscription
  # manager keeps: they carry the same user, customer and subscription ids, and
  # the subscription's status rides in their metadata.
  defp stub_lookups_over_transactions do
    stub(SubscriptionManagerMock, :get_subscription_by_customer_id, fn id ->
      PaymentTransactionSchema |> Repo.get_by(stripe_customer_id: id) |> as_subscription()
    end)

    stub(SubscriptionManagerMock, :get_subscription_by_subscription_id, fn id ->
      PaymentTransactionSchema |> Repo.get_by(subscription_id: id) |> as_subscription()
    end)
  end

  defp as_subscription(nil), do: nil

  defp as_subscription(transaction),
    do: %{
      user_id: transaction.user_id,
      status: transaction.metadata["subscription_status"],
      stripe_subscription_id: transaction.subscription_id
    }

  defp with_object(event, object), do: Map.put(event, "data", %{"object" => object})

  # The event as Stripe sends it for one refund among several: the charge as
  # it stood once this refund was made, and what it had refunded before.
  defp for_refund(event, charge, previously_refunded) do
    Map.put(event, "data", %{
      "object" => charge,
      "previous_attributes" => %{"amount_refunded" => previously_refunded}
    })
  end

  defp restore(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore(key, value), do: Application.put_env(:tymeslot, key, value)

  defp linked_subscription(opts \\ []) do
    user = insert(:user)

    customer_id = Keyword.get(opts, :customer_id, "cus_#{System.unique_integer([:positive])}")

    # Stands in for a subscription row, so it carries the status of a live
    # subscription: only a live one has access a refund can end.
    insert(:payment_transaction,
      user: user,
      status: :completed,
      metadata: %{"subscription_status" => "active"},
      stripe_customer_id: customer_id,
      subscription_id: "sub_current"
    )

    {user, customer_id}
  end

  defp refunded_charge(customer_id, refunded_cents, charge_cents, invoice_id \\ nil) do
    %{
      "id" => "ch_test_#{System.unique_integer([:positive])}",
      "customer" => customer_id,
      "amount" => charge_cents,
      "amount_refunded" => refunded_cents,
      "currency" => "eur",
      "invoice" => invoice_id
    }
  end

  defp refunded_event(id \\ nil) do
    %{"id" => id || "evt_#{System.unique_integer([:positive])}", "type" => "charge.refunded"}
  end

  describe "handle/1 — charge.refunded" do
    # Revocation has exactly one path: the payment-event handler, which gets
    # the decision in the event. The handler no longer also flips the
    # subscription through the manager, a second, local-only revocation
    # that left the subscription billing at Stripe.
    test "full refund hands the revocation to the payment-event handler and notifies the user" do
      {user, customer_id} = linked_subscription()

      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_current",
          subscription_id: "sub_current"
        })

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_current")
      event = refunded_event()

      assert {:ok, :refund_processed} = RefundHandler.handle(with_object(event, charge))

      # The payment event carries the revocation decision
      assert_received %{
        event: :charge_refunded,
        data: %{
          customer_id: ^customer_id,
          total_refunded: 10_000,
          charge_amount: 10_000,
          refund_percentage: 100.0,
          should_revoke: true,
          invoice_id: "in_current",
          subscription_id: "sub_current"
        }
      }

      user_id = user.id
      # Email quotes this refund's amount and says access was revoked
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "revoked"}
    end

    test "partial refund below threshold does NOT revoke access but still notifies" do
      {user, customer_id} = linked_subscription()

      # 50% refund — below the default 90% threshold
      charge = refunded_charge(customer_id, 5_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_processed} = RefundHandler.handle(with_object(event, charge))

      assert_received %{
        event: :charge_refunded,
        data: %{customer_id: ^customer_id, should_revoke: false}
      }

      user_id = user.id
      # Email is sent without revocation copy, quoting this refund's amount
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 5_000, "eur", "partial"}
    end

    test "a refund the app already announced revokes without a second email" do
      {user, customer_id} = linked_subscription()
      # As Stripe sends it at current API versions: no refunds on the charge.
      charge = refunded_charge(customer_id, 10_000, 10_000)
      charge_id = charge["id"]

      expect(StripeMock, :list_refunds, fn %{charge: ^charge_id, limit: 100} ->
        {:ok,
         %{
           data: [%{id: "re_1", amount: 10_000, metadata: %{"customer_notified" => "true"}}],
           has_more: false
         }}
      end)

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      assert_received %{event: :charge_refunded, data: %{should_revoke: true}}

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      refute_received {:refund_email, ^user_id, _amount, _currency, _revoked}
    end

    test "a refund read from Stripe without the flag is emailed with its own amount" do
      {user, customer_id} = linked_subscription()
      charge = refunded_charge(customer_id, 10_000, 10_000)

      expect(StripeMock, :list_refunds, fn _params ->
        {:ok, %{data: [%{id: "re_2", amount: 6_000, metadata: %{}}], has_more: false}}
      end)

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 6_000, "eur", _revoked}
    end

    test "a failed read of the latest refund still sends the refund email" do
      {user, customer_id} = linked_subscription()
      charge = refunded_charge(customer_id, 5_000, 10_000)

      expect(StripeMock, :list_refunds, fn _params -> {:error, :timeout} end)

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 5_000, "eur", "partial"}
    end

    test "an earlier announced refund on the payload does not silence a later one" do
      {user, customer_id} = linked_subscription()

      charge =
        customer_id
        |> refunded_charge(10_000, 10_000)
        |> Map.put("refunds", %{
          "data" => [
            %{"amount" => 4_000, "created" => 1, "metadata" => %{"customer_notified" => "true"}},
            %{"amount" => 6_000, "created" => 2, "metadata" => %{}}
          ]
        })

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 6_000, "eur", _revoked}
    end

    # Two refunds on one charge, one the app announced (A, 4,000) and one made
    # by hand in the Stripe dashboard (B, 6,000), each delivered late, once
    # both exist at Stripe. The newest refund is the other event's, so each
    # event is matched to its own refund by the amount it added.
    test "late events for an announced refund and a later manual one email the manual one once" do
      {user, customer_id} = linked_subscription()
      charge_id = "ch_test_#{System.unique_integer([:positive])}"

      stub(StripeMock, :list_refunds, fn %{charge: ^charge_id} ->
        {:ok,
         %{
           data: [
             %{id: "re_b", amount: 6_000, created: 2, metadata: %{}},
             %{id: "re_a", amount: 4_000, created: 1, metadata: %{"customer_notified" => "true"}}
           ],
           has_more: false
         }}
      end)

      for {refunded, previous} <- [{4_000, 0}, {10_000, 4_000}] do
        charge = Map.put(refunded_charge(customer_id, refunded, 10_000), "id", charge_id)

        assert {:ok, :refund_processed} =
                 RefundHandler.handle(for_refund(refunded_event(), charge, previous))
      end

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 6_000, "eur", _revoked}
      refute_received {:refund_email, ^user_id, _amount, _currency, _revoked}
    end

    test "late events for a manual refund and a later announced one email the manual one once" do
      {user, customer_id} = linked_subscription()
      charge_id = "ch_test_#{System.unique_integer([:positive])}"

      stub(StripeMock, :list_refunds, fn %{charge: ^charge_id} ->
        {:ok,
         %{
           data: [
             %{id: "re_a", amount: 4_000, created: 2, metadata: %{"customer_notified" => "true"}},
             %{id: "re_b", amount: 6_000, created: 1, metadata: %{}}
           ],
           has_more: false
         }}
      end)

      for {refunded, previous} <- [{6_000, 0}, {10_000, 6_000}] do
        charge = Map.put(refunded_charge(customer_id, refunded, 10_000), "id", charge_id)

        assert {:ok, :refund_processed} =
                 RefundHandler.handle(for_refund(refunded_event(), charge, previous))
      end

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 6_000, "eur", _revoked}
      refute_received {:refund_email, ^user_id, _amount, _currency, _revoked}
    end

    # Two refunds of the same amount, one announced and one not: the event
    # could be about either, so the customer is told rather than risk silence.
    test "an event matching an announced and an unannounced refund alike is emailed" do
      {user, customer_id} = linked_subscription()
      charge = refunded_charge(customer_id, 10_000, 10_000)

      stub(StripeMock, :list_refunds, fn _params ->
        {:ok,
         %{
           data: [
             %{id: "re_2", amount: 5_000, created: 2, metadata: %{}},
             %{id: "re_1", amount: 5_000, created: 1, metadata: %{"customer_notified" => "true"}}
           ],
           has_more: false
         }}
      end)

      assert {:ok, :refund_processed} =
               RefundHandler.handle(for_refund(refunded_event(), charge, 5_000))

      Oban.drain_queue(queue: :emails)
      user_id = user.id
      assert_received {:refund_email, ^user_id, 5_000, "eur", _revoked}
    end

    test "refund without a linked subscription is logged without user-facing side effects" do
      # No matching subscription exists in the DB
      charge = refunded_charge("cus_orphan", 10_000, 10_000)
      event = refunded_event()

      assert {:ok, :refund_logged} = RefundHandler.handle(with_object(event, charge))

      # Global event still fires for the orphan refund
      assert_received %{
        event: :charge_refunded,
        data: %{customer_id: "cus_orphan", total_refunded: 10_000}
      }

      # No linked user, so nobody to email
      refute_received {:refund_email, _user_id, _amount, _currency, _revoked}
    end

    test "names the subscription the refunded charge paid for, when its invoice is known" do
      {_user, customer_id} = linked_subscription()

      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_refunded",
          subscription_id: "sub_paid_for"
        })

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_refunded")

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      assert_received %{
        event: :charge_refunded,
        data: %{invoice_id: "in_refunded", subscription_id: "sub_paid_for"}
      }
    end

    # The hand-off above only queues the revocation; the email must not
    # promise access ends when the refund is not for the subscription the
    # customer holds now.
    test "a full refund of an ended subscription's charge tells the user nothing live changed" do
      user = insert(:user)
      customer_id = "cus_#{System.unique_integer([:positive])}"

      insert(:payment_transaction,
        user: user,
        status: :completed,
        metadata: %{"subscription_status" => "canceled"},
        stripe_customer_id: customer_id,
        subscription_id: "sub_ended"
      )

      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_ended",
          subscription_id: "sub_ended"
        })

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_ended")

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      user_id = user.id
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "unaffected"}
    end

    test "a full refund of a charge with no invoice does not tell the user access ended" do
      {user, customer_id} = linked_subscription()

      charge = refunded_charge(customer_id, 10_000, 10_000)

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      user_id = user.id
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "unaffected"}
    end

    test "a full refund of an earlier subscription's charge does not tell the user access ended" do
      {user, customer_id} = linked_subscription()

      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_earlier",
          subscription_id: "sub_earlier"
        })

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_earlier")

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      user_id = user.id
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "unaffected"}
    end

    # Invoices are recorded only from when recording began. A customer who
    # resubscribed since an older invoice holds a newer subscription; the
    # refund must name the one Stripe says the invoice billed, never the
    # customer's current one.
    test "a refund of an invoice paid before invoices were recorded names its own subscription" do
      {user, customer_id} = linked_subscription()

      expect(StripeMock, :get_invoice, fn "in_before_recording" ->
        {:ok, %{id: "in_before_recording", subscription: "sub_before_resubscribing"}}
      end)

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_before_recording")

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      assert_received %{
        event: :charge_refunded,
        data: %{
          invoice_id: "in_before_recording",
          subscription_id: "sub_before_resubscribing",
          should_revoke: true
        }
      }

      user_id = user.id
      # The notice goes out from a job; the current subscription carries on.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "unaffected"}
    end

    # From API version 2025-03-31.basil a charge no longer names its
    # invoice; the invoice is found through the charge's payment intent.
    test "a charge that does not name its invoice is traced through its payment intent" do
      {user, customer_id} = linked_subscription()

      expect(StripeMock, :list_invoice_payments, fn %{
                                                      payment: %{
                                                        type: "payment_intent",
                                                        payment_intent: "pi_current"
                                                      }
                                                    } ->
        {:ok, %{data: [%{invoice: "in_current"}], has_more: false}}
      end)

      expect(StripeMock, :get_invoice, fn "in_current" ->
        {:ok,
         %{id: "in_current", parent: %{subscription_details: %{subscription: "sub_current"}}}}
      end)

      charge =
        customer_id
        |> refunded_charge(10_000, 10_000)
        |> Map.delete("invoice")
        |> Map.put("payment_intent", "pi_current")

      assert {:ok, :refund_processed} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      assert_received %{
        event: :charge_refunded,
        data: %{invoice_id: "in_current", subscription_id: "sub_current", should_revoke: true}
      }

      user_id = user.id
      # The notice goes out from a job.
      Oban.drain_queue(queue: :emails)
      assert_received {:refund_email, ^user_id, 10_000, "eur", "revoked"}
    end

    test "a failed Stripe lookup retries the delivery instead of guessing the subscription" do
      {_user, customer_id} = linked_subscription()

      expect(StripeMock, :get_invoice, fn "in_before_recording" -> {:error, :timeout} end)

      charge = refunded_charge(customer_id, 10_000, 10_000, "in_before_recording")

      assert {:error, :retry_later, {:stripe_lookup_failed, :timeout}} =
               RefundHandler.handle(with_object(refunded_event(), charge))

      refute_received %{event: :charge_refunded}
      Oban.drain_queue(queue: :emails)
      refute_received {:refund_email, _user_id, _amount, _currency, _revoked}
    end

    test "a handler failure returns retry_later and skips the user notification" do
      Application.put_env(:tymeslot, :payment_event_handler, FailingHandler)
      {_user, customer_id} = linked_subscription()

      charge = refunded_charge(customer_id, 10_000, 10_000)
      event = refunded_event()

      assert {:error, :retry_later, {:hand_off_failed, :downstream_unavailable}} =
               RefundHandler.handle(with_object(event, charge))

      refute_received {:refund_email, _user_id, _amount, _currency, _revoked}
    end
  end

  describe "handle/1 — charge.refund.updated" do
    test "acknowledges status changes without side effects" do
      refund = %{"id" => "re_123", "status" => "succeeded"}
      event = %{"id" => "evt_456", "type" => "charge.refund.updated"}

      assert {:ok, :refund_status_updated} = RefundHandler.handle(with_object(event, refund))

      refute_received {:refund_email, _user_id, _amount, _currency, _revoked}
    end
  end
end
