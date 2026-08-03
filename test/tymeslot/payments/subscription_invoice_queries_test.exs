defmodule Tymeslot.Payments.SubscriptionInvoiceQueriesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionInvoiceSchema
  alias Tymeslot.TestFixtures

  setup do
    %{user: TestFixtures.create_user_fixture()}
  end

  describe "upsert/1" do
    test "inserts a new invoice", %{user: user} do
      assert {:ok, invoice} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_new",
                 user_id: user.id,
                 number: "A1B2C3-0001",
                 currency: "eur",
                 amount_cents: 1500,
                 hosted_invoice_url: "https://invoice.stripe.com/i/new",
                 invoice_pdf_url: "https://pay.stripe.com/invoice/new/pdf"
               })

      assert invoice.stripe_invoice_id == "in_new"
      assert invoice.number == "A1B2C3-0001"
      assert invoice.amount_cents == 1500
    end

    test "merges a second upsert for the same stripe_invoice_id into one row", %{user: user} do
      assert {:ok, first} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_merge",
                 user_id: user.id,
                 hosted_invoice_url: "https://invoice.stripe.com/i/merge"
               })

      assert {:ok, second} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_merge",
                 user_id: user.id,
                 number: "A1B2C3-0002",
                 amount_cents: 2000,
                 invoice_pdf_url: "https://pay.stripe.com/invoice/merge/pdf"
               })

      assert second.id == first.id
      assert second.hosted_invoice_url == "https://invoice.stripe.com/i/merge"
      assert second.number == "A1B2C3-0002"
      assert second.amount_cents == 2000
      assert second.invoice_pdf_url == "https://pay.stripe.com/invoice/merge/pdf"

      assert Repo.aggregate(SubscriptionInvoiceSchema, :count) == 1
    end

    test "never blanks a field a previous upsert already captured", %{user: user} do
      assert {:ok, _first} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_no_blank",
                 user_id: user.id,
                 number: "A1B2C3-0003",
                 currency: "eur",
                 amount_cents: 1200,
                 hosted_invoice_url: "https://invoice.stripe.com/i/no-blank",
                 invoice_pdf_url: "https://pay.stripe.com/invoice/no-blank/pdf"
               })

      # A later event that carries no document fields (only a fresh
      # amount_cents, e.g. from invoice.paid) must not erase what the first
      # event already captured.
      assert {:ok, merged} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_no_blank",
                 user_id: user.id,
                 amount_cents: 1200
               })

      assert merged.number == "A1B2C3-0003"
      assert merged.currency == "eur"
      assert merged.hosted_invoice_url == "https://invoice.stripe.com/i/no-blank"
      assert merged.invoice_pdf_url == "https://pay.stripe.com/invoice/no-blank/pdf"
    end

    test "fills in a user_id the first capture could not resolve" do
      assert {:ok, first} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_late_user",
                 user_id: nil
               })

      assert first.user_id == nil

      user = TestFixtures.create_user_fixture()

      assert {:ok, second} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_late_user",
                 user_id: user.id
               })

      assert second.user_id == user.id
    end

    test "converges status from the invoice being finalised to being voided", %{user: user} do
      assert {:ok, finalized} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_status_transition",
                 user_id: user.id,
                 status: :open
               })

      assert finalized.status == :open

      assert {:ok, voided} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_status_transition",
                 user_id: user.id,
                 status: :void
               })

      assert voided.id == finalized.id
      assert voided.status == :void
    end

    test "converges status from open to paid, not frozen by a COALESCE against the first value",
         %{user: user} do
      assert {:ok, _open} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_status_open_to_paid",
                 user_id: user.id,
                 status: :open
               })

      assert {:ok, paid} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_status_open_to_paid",
                 user_id: user.id,
                 status: :paid
               })

      assert paid.status == :paid
    end
  end

  describe "list_for_user/2" do
    test "returns a user's invoices, newest issued first", %{user: user} do
      older =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_older",
          user_id: user.id,
          issued_at: ~U[2026-01-01 00:00:00Z],
          status: :paid
        })

      newer =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_newer",
          user_id: user.id,
          issued_at: ~U[2026-02-01 00:00:00Z],
          status: :paid
        })

      {:ok, older} = older
      {:ok, newer} = newer

      assert [^newer, ^older] = SubscriptionInvoiceQueries.list_for_user(user.id)
    end

    test "does not leak another user's invoices", %{user: user} do
      other = TestFixtures.create_user_fixture()

      SubscriptionInvoiceQueries.upsert(%{stripe_invoice_id: "in_other_user", user_id: other.id})

      assert SubscriptionInvoiceQueries.list_for_user(user.id) == []
    end

    test "excludes unpaid and voided invoices — only a paid invoice is a receipt", %{user: user} do
      for {stripe_invoice_id, status} <- [
            {"in_draft", :draft},
            {"in_open", :open},
            {"in_void", :void},
            {"in_uncollectible", :uncollectible}
          ] do
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: stripe_invoice_id,
          user_id: user.id,
          issued_at: DateTime.utc_now(),
          status: status
        })
      end

      assert SubscriptionInvoiceQueries.list_for_user(user.id) == []

      {:ok, paid} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_actually_paid",
          user_id: user.id,
          issued_at: DateTime.utc_now(),
          status: :paid
        })

      assert [listed] = SubscriptionInvoiceQueries.list_for_user(user.id)
      assert listed.id == paid.id
    end

    test "breaks a tied issued_at with id, deterministically ordering the pair", %{user: user} do
      tie = ~U[2026-04-01 00:00:00Z]

      {:ok, first} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_tie_first",
          user_id: user.id,
          issued_at: tie,
          status: :paid
        })

      {:ok, second} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_tie_second",
          user_id: user.id,
          issued_at: tie,
          status: :paid
        })

      assert [^second, ^first] = SubscriptionInvoiceQueries.list_for_user(user.id)
    end

    test "honours the limit", %{user: user} do
      for number <- 1..3 do
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_limit_#{number}",
          user_id: user.id,
          issued_at: DateTime.utc_now(),
          status: :paid
        })
      end

      assert length(SubscriptionInvoiceQueries.list_for_user(user.id, 2)) == 2
    end
  end

  describe "anonymise_for_host/2" do
    test "nilifies user_id, stamps host_deleted_at, and retains the VAT document surface", %{
      user: user
    } do
      {:ok, invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_anonymise",
          user_id: user.id,
          subscription_id: "sub_123",
          number: "A1B2C3-0004",
          currency: "eur",
          amount_cents: 3400,
          issued_at: ~U[2026-03-01 00:00:00Z],
          hosted_invoice_url: "https://invoice.stripe.com/i/anonymise",
          invoice_pdf_url: "https://pay.stripe.com/invoice/anonymise/pdf"
        })

      now = DateTime.utc_now(:second)
      assert {1, nil} = SubscriptionInvoiceQueries.anonymise_for_host(user.id, now)

      reloaded = Repo.get!(SubscriptionInvoiceSchema, invoice.id)

      # Identifying link to the host account is severed.
      assert reloaded.user_id == nil
      assert reloaded.host_deleted_at == now

      # The VAT document surface is deliberately retained — see the
      # function's own docs for why (the URLs are the entire user-facing
      # value of a retained tax record; subscription_id explains what the
      # document billed).
      assert reloaded.subscription_id == "sub_123"
      assert reloaded.number == "A1B2C3-0004"
      assert reloaded.currency == "eur"
      assert reloaded.amount_cents == 3400
      assert reloaded.issued_at == ~U[2026-03-01 00:00:00Z]
      assert reloaded.hosted_invoice_url == "https://invoice.stripe.com/i/anonymise"
      assert reloaded.invoice_pdf_url == "https://pay.stripe.com/invoice/anonymise/pdf"
    end

    test "is a no-op for a host with no captured invoices", %{user: user} do
      now = DateTime.utc_now(:second)
      assert {0, nil} = SubscriptionInvoiceQueries.anonymise_for_host(user.id, now)
    end

    test "is idempotent — re-running does not re-stamp an already anonymised row", %{user: user} do
      {:ok, invoice} =
        SubscriptionInvoiceQueries.upsert(%{stripe_invoice_id: "in_idempotent", user_id: user.id})

      first_now = DateTime.utc_now(:second)
      assert {1, nil} = SubscriptionInvoiceQueries.anonymise_for_host(user.id, first_now)

      first_stamp = Repo.get!(SubscriptionInvoiceSchema, invoice.id).host_deleted_at
      assert first_stamp == first_now

      later_now = DateTime.add(first_now, 60, :second)
      assert {0, nil} = SubscriptionInvoiceQueries.anonymise_for_host(user.id, later_now)

      assert Repo.get!(SubscriptionInvoiceSchema, invoice.id).host_deleted_at == first_stamp
    end

    test "survives a direct user delete via the on_delete: :nilify_all FK safety net", %{
      user: user
    } do
      {:ok, invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_fk_safety_net",
          user_id: user.id
        })

      assert {:ok, _deleted} = Repo.delete(user)

      survived = Repo.get(SubscriptionInvoiceSchema, invoice.id)

      assert survived,
             "subscription_invoice must survive a user delete via :nilify_all FK, " <>
               "even without the retention pre-pass"

      assert survived.user_id == nil
    end

    test "a replayed capture for the same invoice cannot re-link user_id after anonymisation", %{
      user: user
    } do
      {:ok, invoice} =
        SubscriptionInvoiceQueries.upsert(%{stripe_invoice_id: "in_replay", user_id: user.id})

      now = DateTime.utc_now(:second)
      assert {1, nil} = SubscriptionInvoiceQueries.anonymise_for_host(user.id, now)

      other_user = TestFixtures.create_user_fixture()

      assert {:ok, replayed} =
               SubscriptionInvoiceQueries.upsert(%{
                 stripe_invoice_id: "in_replay",
                 user_id: other_user.id
               })

      assert replayed.id == invoice.id
      assert replayed.user_id == nil
      assert %DateTime{} = replayed.host_deleted_at
    end
  end
end
