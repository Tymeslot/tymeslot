defmodule Tymeslot.Payments.SubscriptionInvoicesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  import ExUnit.CaptureLog

  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.SubscriptionInvoice
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionInvoices
  alias Tymeslot.Payments.Webhooks.InvoiceEvent
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.TestFixtures

  setup do
    %{user: TestFixtures.create_user_fixture()}
  end

  describe "capture/1" do
    test "captures an invoice with no matching transaction anywhere, logging the unresolved owner",
         %{user: _user} do
      event = %InvoiceEvent{
        id: "in_orphan",
        customer_id: "cus_orphan",
        subscription_id: "sub_orphan",
        number: "A1B2C3-0001",
        currency: "eur",
        amount_cents: 1500,
        hosted_url: "https://invoice.stripe.com/i/orphan"
      }

      {result, log} = with_log(fn -> SubscriptionInvoices.capture(event) end)

      assert {:ok, invoice} = result
      assert invoice.stripe_invoice_id == "in_orphan"
      assert invoice.user_id == nil
      assert invoice.number == "A1B2C3-0001"
      assert invoice.amount_cents == 1500
      assert log =~ "Captured invoice with no resolvable owner"
    end

    test "resolves the owning user via the invoice's subscription id", %{user: user} do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        stripe_id: "sess_sub_fallback",
        subscription_id: "sub_fallback"
      })

      event = %InvoiceEvent{id: "in_sub_fallback", subscription_id: "sub_fallback"}

      assert {:ok, invoice} = SubscriptionInvoices.capture(event)

      assert invoice.user_id == user.id
    end

    test "resolves the owning user via the invoice's customer id when the subscription doesn't match",
         %{user: user} do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        stripe_id: "sess_customer_fallback",
        stripe_customer_id: "cus_customer_fallback"
      })

      event = %InvoiceEvent{
        id: "in_customer_fallback",
        customer_id: "cus_customer_fallback",
        subscription_id: "sub_unrelated"
      }

      assert {:ok, invoice} = SubscriptionInvoices.capture(event)

      assert invoice.user_id == user.id
    end

    test "never attributes ownership from a pending or failed transaction", %{user: user} do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "pending",
        stripe_id: "sess_pending_only",
        subscription_id: "sub_pending_only",
        stripe_customer_id: "cus_pending_only"
      })

      event = %InvoiceEvent{
        id: "in_pending_only",
        customer_id: "cus_pending_only",
        subscription_id: "sub_pending_only"
      }

      assert {:ok, invoice} = SubscriptionInvoices.capture(event)

      assert invoice.user_id == nil
    end

    test "resolves the owning user via the invoice's subscription metadata, ahead of any database lookup",
         %{user: user} do
      # A subscription's first invoice can arrive before checkout.session.completed
      # has written any local transaction or subscription row, so the metadata
      # Stripe echoes back from checkout is the only ownership signal available.
      event = %InvoiceEvent{
        id: "in_metadata_owner",
        subscription_id: "sub_never_persisted_locally",
        customer_id: "cus_never_persisted_locally",
        billing_reason: "subscription_create",
        number: "A1B2C3-0042",
        metadata_user_id: user.id,
        status: "paid"
      }

      assert {:ok, invoice} = SubscriptionInvoices.capture(event)

      assert invoice.user_id == user.id
      assert [listed] = SubscriptionInvoices.list(user.id)
      assert listed.number == "A1B2C3-0042"
    end

    test "an invoice whose resolved owner is an already-deleted user is still persisted, with no owner" do
      deleted_user = TestFixtures.create_user_fixture()
      deleted_user_id = deleted_user.id
      Repo.delete!(deleted_user)

      event = %InvoiceEvent{
        id: "in_deleted_owner",
        subscription_id: "sub_deleted_owner",
        metadata_user_id: deleted_user_id
      }

      {result, log} = with_log(fn -> SubscriptionInvoices.capture(event) end)

      assert {:ok, invoice} = result
      assert invoice.stripe_invoice_id == "in_deleted_owner"
      assert invoice.user_id == nil
      assert log =~ "since-deleted user"
    end
  end

  describe "coordinate_renewal/1" do
    test "does nothing for the subscription's first invoice", %{user: user} do
      transaction =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "completed",
          subscription_id: "sub_create",
          stripe_id: "sess_create"
        })

      event = %InvoiceEvent{
        id: "in_create",
        subscription_id: "sub_create",
        billing_reason: "subscription_create"
      }

      assert {:ok, :already_processed} = SubscriptionInvoices.coordinate_renewal(event)

      # No new row created for the subscription's first invoice.
      assert Repo.reload!(transaction).stripe_id == "sess_create"
    end

    test "creates a new transaction for a renewal invoice, carrying its own amount and metadata",
         %{user: user} do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        subscription_id: "sub_cycle",
        stripe_id: "sess_cycle",
        amount: 1000
      })

      event = %InvoiceEvent{
        id: "in_cycle_2",
        subscription_id: "sub_cycle",
        billing_reason: "subscription_cycle",
        amount_paid: 1200,
        created: 1_700_000_000
      }

      assert {:ok, renewal} = SubscriptionInvoices.coordinate_renewal(event)

      assert renewal.stripe_id == "in_cycle_2"
      assert renewal.amount == 1200
      assert renewal.status == "completed"
      assert renewal.metadata[:renewal_invoice_id] == "in_cycle_2"
      assert renewal.metadata[:renewal_date] == 1_700_000_000
    end

    test "returns an error when the subscription has no active transaction" do
      event = %InvoiceEvent{id: "in_missing", subscription_id: "sub_missing"}

      assert {:error, :subscription_not_found} = SubscriptionInvoices.coordinate_renewal(event)
    end

    test "treats a duplicate renewal delivery as already processed, creating only one row", %{
      user: user
    } do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        subscription_id: "sub_dupe",
        stripe_id: "sess_dupe"
      })

      event = %InvoiceEvent{
        id: "in_dupe",
        subscription_id: "sub_dupe",
        billing_reason: "subscription_cycle",
        amount_paid: 900
      }

      assert {:ok, first} = SubscriptionInvoices.coordinate_renewal(event)
      assert {:ok, :already_processed} = SubscriptionInvoices.coordinate_renewal(event)

      assert [only] =
               Repo.all(from(t in PaymentTransactionSchema, where: t.stripe_id == "in_dupe"))

      assert only.id == first.id
    end

    test "never mutates a legacy checkout-session transaction with no invoice", %{user: user} do
      legacy =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "completed",
          subscription_id: "sub_legacy",
          stripe_id: "cs_legacy_checkout",
          amount: 1000
        })

      event = %InvoiceEvent{
        id: "in_legacy_renewal",
        subscription_id: "sub_legacy",
        billing_reason: "subscription_cycle",
        amount_paid: 1000
      }

      assert {:ok, _renewal} = SubscriptionInvoices.coordinate_renewal(event)

      untouched = Repo.reload!(legacy)
      assert untouched.stripe_id == "cs_legacy_checkout"
      assert untouched.amount == 1000
    end
  end

  describe "list/2" do
    test "builds an Invoice read model sourced from the invoice, not the transaction", %{
      user: user
    } do
      # The transaction was initiated days before the invoice was actually
      # issued (e.g. a trial), and for a different amount (pre-tax/promo) —
      # the read model must reflect the invoice's own values, not these.
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "completed",
        amount: 999,
        subscription_id: "sub_list",
        stripe_id: "sess_list",
        inserted_at: ~U[2026-01-01 00:00:00Z]
      })

      event = %InvoiceEvent{
        id: "in_list",
        subscription_id: "sub_list",
        number: "A1B2C3-0001",
        currency: "eur",
        amount_cents: 1500,
        issued_at: ~U[2026-02-15 00:00:00Z],
        hosted_url: "https://invoice.stripe.com/i/abc",
        pdf_url: "https://pay.stripe.com/invoice/abc/pdf",
        status: "paid"
      }

      assert {:ok, _invoice} = SubscriptionInvoices.capture(event)

      assert [%SubscriptionInvoice{} = invoice] = SubscriptionInvoices.list(user.id)

      assert invoice.number == "A1B2C3-0001"
      assert invoice.issued_at == ~U[2026-02-15 00:00:00Z]
      assert invoice.amount_cents == 1500
      assert invoice.currency == "eur"
      assert invoice.hosted_url == "https://invoice.stripe.com/i/abc"
      assert invoice.pdf_url == "https://pay.stripe.com/invoice/abc/pdf"
      assert invoice.status == :paid
    end

    test "omits nothing but a user's own invoices", %{user: user} do
      other = TestFixtures.create_user_fixture()

      SubscriptionInvoiceQueries.upsert(%{
        stripe_invoice_id: "in_other_user",
        user_id: other.id
      })

      assert SubscriptionInvoices.list(user.id) == []
    end
  end
end
