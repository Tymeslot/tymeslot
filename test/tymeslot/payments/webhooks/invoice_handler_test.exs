defmodule Tymeslot.Payments.Webhooks.InvoiceHandlerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.SubscriptionInvoices
  alias Tymeslot.Payments.SubscriptionInvoiceSchema
  alias Tymeslot.Payments.Webhooks.{InvoiceHandler, WebhookRegistry}
  import Tymeslot.Factory

  defp invoice_for(stripe_invoice_id),
    do: Repo.get_by(SubscriptionInvoiceSchema, stripe_invoice_id: stripe_invoice_id)

  describe "can_handle?/1" do
    test "returns true for supported invoice events" do
      assert InvoiceHandler.can_handle?("invoice.created")
      assert InvoiceHandler.can_handle?("invoice.finalized")
      assert InvoiceHandler.can_handle?("invoice.paid")
      assert InvoiceHandler.can_handle?("invoice.payment_succeeded")
      assert InvoiceHandler.can_handle?("invoice.payment_failed")
      assert InvoiceHandler.can_handle?("invoice.upcoming")
      assert InvoiceHandler.can_handle?("invoice.voided")
      assert InvoiceHandler.can_handle?("invoice.marked_uncollectible")
    end

    test "returns false for unsupported events" do
      refute InvoiceHandler.can_handle?("customer.created")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid invoice" do
      assert InvoiceHandler.validate(%{"id" => "in_123"}) == :ok
    end

    test "returns error for missing or empty id" do
      assert {:error, :missing_field, _message} = InvoiceHandler.validate(%{})
      assert {:error, :missing_field, _message} = InvoiceHandler.validate(%{"id" => ""})
    end
  end

  describe "validate/2" do
    test "allows upcoming invoices without an id" do
      assert InvoiceHandler.validate("invoice.upcoming", %{}) == :ok
    end

    test "requires id for non-upcoming invoice events" do
      assert {:error, :missing_field, _message} = InvoiceHandler.validate("invoice.created", %{})
    end
  end

  describe "webhook registry validation" do
    test "uses event-aware validation for upcoming invoices" do
      # Mock find_handler to return InvoiceHandler for invoice.upcoming
      # This test might be failing because find_handler is not finding the handler
      # or the registry's own logic changed.
      assert :ok = WebhookRegistry.validate("invoice.upcoming", %{})
    end

    test "rejects missing ids for other invoice events" do
      # invoice.paid requires an ID in InvoiceHandler.validate/2
      assert {:error, :missing_field, "Invoice ID missing"} =
               WebhookRegistry.validate("invoice.paid", %{})
    end
  end

  describe "process/2" do
    test "handles invoice.payment_succeeded" do
      user = insert(:user)
      subscription_id = "sub_123"

      # Create an existing transaction for this subscription
      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_123"
      )

      invoice = %{
        "id" => "in_123",
        "subscription" => subscription_id,
        "amount_paid" => 1000,
        "currency" => "eur",
        "status" => "paid"
      }

      event = %{type: "invoice.payment_succeeded"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(event, invoice)

      # Verify a new transaction was created for the renewal
      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      # One initial + one renewal
      assert length(transactions) == 2
    end

    test "invoice.finalized captures the invoice document, owner resolved via the subscription" do
      user = insert(:user)
      subscription_id = "sub_finalized"

      # A subscription's first transaction is keyed on the checkout session,
      # not the invoice, so ownership is resolved via the subscription id
      # instead.
      transaction =
        insert(:payment_transaction,
          user: user,
          subscription_id: subscription_id,
          status: "completed",
          stripe_id: "sess_finalized"
        )

      invoice = %{
        "id" => "in_finalized",
        "subscription" => subscription_id,
        "number" => "A1B2C3-0001",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/finalized",
        "invoice_pdf" => "https://pay.stripe.com/invoice/finalized/pdf"
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, invoice)

      captured = invoice_for("in_finalized")
      assert captured.user_id == user.id
      assert captured.number == "A1B2C3-0001"
      assert captured.hosted_invoice_url == "https://invoice.stripe.com/i/finalized"
      assert captured.invoice_pdf_url == "https://pay.stripe.com/invoice/finalized/pdf"

      # The transaction itself is never touched by document capture — it no
      # longer carries any invoice-document columns at all.
      assert Repo.reload!(transaction).stripe_id == "sess_finalized"
    end

    test "invoice.finalized without a matching transaction still acknowledges the event and captures the invoice" do
      # Stripe finalises before charging, so the transaction may not exist yet.
      # Failing here would make Stripe redeliver an event whose payment side
      # has already succeeded.
      invoice = %{
        "id" => "in_orphan",
        "subscription" => "sub_nonexistent",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/orphan"
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, invoice)

      captured = invoice_for("in_orphan")
      assert captured.hosted_invoice_url == "https://invoice.stripe.com/i/orphan"
      assert captured.user_id == nil
    end

    test "an invoice with no matching subscription is still captured and listed, owner resolved via the Stripe customer" do
      user = insert(:user)

      # A completed transaction for the same Stripe customer: nothing about
      # it matches this invoice's id or subscription (no transaction is
      # linked to this specific invoice or subscription), but a completed
      # charge for the same customer is a valid ownership signal.
      insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_id: "sess_out_of_band",
        stripe_customer_id: "cus_out_of_band"
      )

      invoice = %{
        "id" => "in_out_of_band",
        "customer" => "cus_out_of_band",
        "subscription" => "sub_never_created_locally",
        "number" => "A1B2C3-0009",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/out-of-band",
        "status" => "paid"
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, invoice)

      captured = invoice_for("in_out_of_band")
      assert captured.user_id == user.id

      assert [listed] = SubscriptionInvoices.list(user.id)
      assert listed.number == "A1B2C3-0009"
      assert listed.hosted_url == "https://invoice.stripe.com/i/out-of-band"
    end

    test "a pending transaction for the same Stripe customer is never an ownership signal" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "pending",
        stripe_id: "sess_pending_only",
        stripe_customer_id: "cus_pending_only"
      )

      invoice = %{
        "id" => "in_pending_only",
        "customer" => "cus_pending_only",
        "subscription" => "sub_never_created_locally",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/pending-only"
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, invoice)

      captured = invoice_for("in_pending_only")
      assert captured.user_id == nil
    end

    test "a renewal creates its transaction row and captures the invoice document" do
      user = insert(:user)
      subscription_id = "sub_renewal_doc"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_renewal_doc"
      )

      invoice = %{
        "id" => "in_renewal_doc",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_cycle",
        "amount_paid" => 900,
        "total" => 900,
        "number" => "A1B2C3-0002",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/renewal",
        "invoice_pdf" => "https://pay.stripe.com/invoice/renewal/pdf"
      }

      assert {:ok, :invoice_processed} =
               InvoiceHandler.process(%{type: "invoice.paid"}, invoice)

      assert {:ok, renewal} = PaymentQueries.get_transaction_by_stripe_id("in_renewal_doc")
      assert renewal.amount == 900

      captured = invoice_for("in_renewal_doc")
      assert captured.number == "A1B2C3-0002"
      assert captured.amount_cents == 900
      assert captured.hosted_invoice_url == "https://invoice.stripe.com/i/renewal"
      assert captured.invoice_pdf_url == "https://pay.stripe.com/invoice/renewal/pdf"
    end

    test "invoice.finalized then invoice.paid for the same invoice converge on one row" do
      user = insert(:user)
      subscription_id = "sub_finalized_then_paid"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_finalized_then_paid"
      )

      finalized = %{
        "id" => "in_finalized_then_paid",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_cycle",
        "number" => "A1B2C3-0010",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/order-a"
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, finalized)

      paid = Map.merge(finalized, %{"amount_paid" => 1100, "total" => 1100})

      assert {:ok, :invoice_processed} = InvoiceHandler.process(%{type: "invoice.paid"}, paid)

      assert Repo.aggregate(
               from(pi in SubscriptionInvoiceSchema,
                 where: pi.stripe_invoice_id == "in_finalized_then_paid"
               ),
               :count
             ) == 1

      captured = invoice_for("in_finalized_then_paid")
      assert captured.number == "A1B2C3-0010"
      assert captured.hosted_invoice_url == "https://invoice.stripe.com/i/order-a"
      assert captured.amount_cents == 1100

      assert {:ok, _renewal} =
               PaymentQueries.get_transaction_by_stripe_id("in_finalized_then_paid")
    end

    test "invoice.paid then invoice.finalized for the same invoice converge identically" do
      user = insert(:user)
      subscription_id = "sub_paid_then_finalized"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_paid_then_finalized"
      )

      paid = %{
        "id" => "in_paid_then_finalized",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_cycle",
        "amount_paid" => 1100,
        "total" => 1100
      }

      assert {:ok, :invoice_processed} = InvoiceHandler.process(%{type: "invoice.paid"}, paid)

      finalized =
        Map.merge(paid, %{
          "number" => "A1B2C3-0011",
          "hosted_invoice_url" => "https://invoice.stripe.com/i/order-b"
        })

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, finalized)

      assert Repo.aggregate(
               from(pi in SubscriptionInvoiceSchema,
                 where: pi.stripe_invoice_id == "in_paid_then_finalized"
               ),
               :count
             ) == 1

      captured = invoice_for("in_paid_then_finalized")
      assert captured.number == "A1B2C3-0011"
      assert captured.hosted_invoice_url == "https://invoice.stripe.com/i/order-b"
      assert captured.amount_cents == 1100

      assert {:ok, _renewal} =
               PaymentQueries.get_transaction_by_stripe_id("in_paid_then_finalized")
    end

    test "two billing cycles each keep their own number, URLs, amount and issue date, and the legacy checkout transaction is never mutated" do
      # Regression coverage for the heuristic-attach bug: a renewal invoice's
      # `invoice.finalized` used to fall back to "newest completed
      # transaction for this subscription" when no row matched its own id,
      # which was the *previous* cycle's row once that cycle had been paid —
      # silently overwriting cycle N-1's invoice number and URLs with cycle
      # N's, and colliding on `stripe_invoice_id`'s unique index when
      # `invoice.paid` then tried to insert the real renewal row. Invoices now
      # have their own table keyed on their own id, and payment_transactions
      # carries no invoice-identity unique index at all, so neither failure
      # mode can occur.
      user = insert(:user)
      subscription_id = "sub_two_cycles"

      checkout_transaction =
        insert(:payment_transaction,
          user: user,
          subscription_id: subscription_id,
          status: "completed",
          stripe_id: "cs_two_cycles_checkout",
          amount: 500
        )

      cycle_one = %{
        "id" => "in_cycle_1",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_create",
        "amount_paid" => 1000,
        "total" => 1000,
        "currency" => "eur",
        "number" => "A1B2C3-0001",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/cycle-1",
        "invoice_pdf" => "https://pay.stripe.com/invoice/cycle-1/pdf",
        "status_transitions" => %{"finalized_at" => 1_700_000_000}
      }

      # finalize N -> paid N
      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, cycle_one)

      assert {:ok, :already_processed} =
               InvoiceHandler.process(%{type: "invoice.paid"}, cycle_one)

      cycle_two = %{
        "id" => "in_cycle_2",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_cycle",
        "amount_paid" => 1200,
        "total" => 1200,
        "currency" => "eur",
        "number" => "A1B2C3-0002",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/cycle-2",
        "invoice_pdf" => "https://pay.stripe.com/invoice/cycle-2/pdf",
        "status_transitions" => %{"finalized_at" => 1_702_600_000}
      }

      # finalize N+1 -> paid N+1
      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, cycle_two)

      # This is the exact webhook call that previously failed with
      # `stripe_invoice_id: has already been taken` once a legacy,
      # never-invoiced checkout transaction existed for the subscription.
      assert {:ok, :invoice_processed} =
               InvoiceHandler.process(%{type: "invoice.paid"}, cycle_two)

      cycle_one_invoice = invoice_for("in_cycle_1")

      # Cycle one never created a new transaction (subscription_create), but
      # ownership still resolves via the shared subscription id.
      assert cycle_one_invoice.user_id == user.id
      assert cycle_one_invoice.number == "A1B2C3-0001"
      assert cycle_one_invoice.hosted_invoice_url == "https://invoice.stripe.com/i/cycle-1"
      assert cycle_one_invoice.invoice_pdf_url == "https://pay.stripe.com/invoice/cycle-1/pdf"
      assert cycle_one_invoice.amount_cents == 1000
      assert cycle_one_invoice.issued_at == DateTime.from_unix!(1_700_000_000)

      cycle_two_invoice = invoice_for("in_cycle_2")
      assert cycle_two_invoice.user_id == user.id
      assert cycle_two_invoice.number == "A1B2C3-0002"
      assert cycle_two_invoice.hosted_invoice_url == "https://invoice.stripe.com/i/cycle-2"
      assert cycle_two_invoice.invoice_pdf_url == "https://pay.stripe.com/invoice/cycle-2/pdf"
      assert cycle_two_invoice.amount_cents == 1200
      assert cycle_two_invoice.issued_at == DateTime.from_unix!(1_702_600_000)

      # The legacy checkout transaction — the pre-existing subscriber's
      # first-cycle row, carrying a cs_… id and no invoice of its own — is
      # never mutated by any of this.
      untouched = Repo.reload!(checkout_transaction)
      assert untouched.stripe_id == "cs_two_cycles_checkout"
      assert untouched.amount == 500
      assert untouched.inserted_at == checkout_transaction.inserted_at
    end

    test "handles invoice.payment_failed" do
      user = insert(:user)
      subscription_id = "sub_fail"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_fail"
      )

      invoice = %{
        "id" => "in_fail",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_cycle",
        "attempt_count" => 1,
        "created" => 1_234_567_890
      }

      event = %{type: "invoice.payment_failed"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(event, invoice)

      # Verify transaction status was updated to pending_reconciliation
      assert {:ok, [t]} =
               PaymentQueries.get_transactions_by_status("pending_reconciliation", user.id)

      assert t.subscription_id == subscription_id
    end

    test "handles invoice.paid" do
      user = insert(:user)
      subscription_id = "sub_paid"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_paid"
      )

      invoice = %{
        "id" => "in_paid",
        "subscription" => subscription_id,
        "amount_paid" => 1000,
        "currency" => "eur",
        "status" => "paid"
      }

      event = %{type: "invoice.paid"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(event, invoice)

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      assert length(transactions) == 2
    end

    test "treats duplicate paid events as already processed" do
      user = insert(:user)
      subscription_id = "sub_dupe"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_dupe"
      )

      invoice = %{
        "id" => "in_dupe",
        "subscription" => subscription_id,
        "amount_paid" => 1000,
        "currency" => "eur",
        "status" => "paid"
      }

      payment_succeeded = %{type: "invoice.payment_succeeded"}
      paid = %{type: "invoice.paid"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(payment_succeeded, invoice)
      assert {:ok, :already_processed} = InvoiceHandler.process(paid, invoice)

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      assert length(transactions) == 2
    end

    test "reads the subscription reference from parent.subscription_details" do
      user = insert(:user)
      subscription_id = "sub_parent_ref"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_parent_ref"
      )

      # Stripe API 2025-03-31.basil and later: the invoice's subscription
      # reference lives under parent.subscription_details instead of the
      # top-level subscription field.
      invoice = %{
        "id" => "in_parent_ref",
        "parent" => %{
          "type" => "subscription_details",
          "subscription_details" => %{"subscription" => subscription_id}
        },
        "amount_paid" => 1000,
        "currency" => "eur",
        "status" => "paid"
      }

      event = %{type: "invoice.paid"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(event, invoice)

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      assert length(transactions) == 2
    end

    test "unwraps an expanded subscription object in parent.subscription_details" do
      user = insert(:user)
      subscription_id = "sub_parent_expanded"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_parent_expanded"
      )

      invoice = %{
        "id" => "in_parent_expanded",
        "parent" => %{
          "type" => "subscription_details",
          "subscription_details" => %{"subscription" => %{"id" => subscription_id}}
        },
        "amount_paid" => 1000,
        "currency" => "eur",
        "status" => "paid"
      }

      event = %{type: "invoice.paid"}

      assert {:ok, :invoice_processed} = InvoiceHandler.process(event, invoice)

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      assert length(transactions) == 2
    end

    test "a subscription's first invoice resolves its owner from subscription metadata when neither a completed transaction nor a subscription row exists yet" do
      # Reproduces the checkout race: invoice.finalized and invoice.paid for a
      # subscription_create invoice can both arrive before
      # checkout.session.completed has written the transaction (still
      # "pending" at best) or the SaaS subscription row. With no completed
      # transaction and no subscription row, the database fallbacks in
      # CustomerLookup.find_user_id/1 all resolve nil — only the subscription
      # metadata Stripe echoes back onto the invoice can resolve the owner.
      user = insert(:user)
      subscription_id = "sub_checkout_race"

      finalized = %{
        "id" => "in_checkout_race",
        "subscription" => subscription_id,
        "billing_reason" => "subscription_create",
        "number" => "A1B2C3-0099",
        "hosted_invoice_url" => "https://invoice.stripe.com/i/checkout-race",
        "parent" => %{
          "subscription_details" => %{
            "subscription" => subscription_id,
            "metadata" => %{"user_id" => to_string(user.id)}
          }
        }
      }

      assert {:ok, :invoice_finalized} =
               InvoiceHandler.process(%{type: "invoice.finalized"}, finalized)

      paid = Map.merge(finalized, %{"amount_paid" => 1000, "total" => 1000, "status" => "paid"})

      assert {:ok, :already_processed} = InvoiceHandler.process(%{type: "invoice.paid"}, paid)

      captured = invoice_for("in_checkout_race")
      assert captured.user_id == user.id

      assert [listed] = SubscriptionInvoices.list(user.id)
      assert listed.number == "A1B2C3-0099"
    end

    test "returns error when subscription not found" do
      invoice = %{"id" => "in_123", "subscription" => "nonexistent"}
      event = %{type: "invoice.payment_succeeded"}

      assert {:error, :retry_later, _error_reason} = InvoiceHandler.process(event, invoice)
    end

    test "returns ok for missing subscription id" do
      invoice = %{"id" => "in_123", "subscription" => nil}
      event = %{type: "invoice.payment_succeeded"}

      assert {:ok, :no_subscription} = InvoiceHandler.process(event, invoice)
    end
  end
end
