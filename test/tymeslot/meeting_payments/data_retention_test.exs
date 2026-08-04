defmodule Tymeslot.MeetingPayments.DataRetentionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.DataRetention
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionInvoiceSchema

  describe "anonymise_host/1" do
    test "scrubs attendee PII, retains host PII, soft-deletes connect, touches both tables" do
      user = insert(:user, email: "host@example.com")
      insert(:connect_account, user: user, status: "active")

      bp =
        insert(:booking_payment,
          host_user_id: user.id,
          host_email: "host@example.com",
          host_name: "Host Person",
          attendee_email: "alice@example.com",
          attendee_name: "Alice",
          meeting_type_name: "Consult"
        )

      pt =
        insert(:payment_transaction,
          user: user,
          host_email: "host@example.com",
          host_name: "Host Person"
        )

      assert :ok = DataRetention.anonymise_host(user.id)

      bp = Repo.reload(bp)
      # host snapshot retained
      assert bp.host_email == "host@example.com"
      assert bp.host_name == "Host Person"
      assert bp.host_user_id == user.id
      # attendee PII scrubbed to nil
      assert is_nil(bp.attendee_email)
      assert is_nil(bp.attendee_name)
      assert bp.meeting_type_name == "[deleted]"
      assert %DateTime{} = bp.host_deleted_at

      pt = Repo.reload(pt)
      assert pt.user_id == nil
      # host snapshot retained on payment_transactions
      assert pt.host_email == "host@example.com"
      assert pt.host_name == "Host Person"
      assert %DateTime{} = pt.host_deleted_at

      # connect_account is soft-deleted and excluded from the live lookup
      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "snapshots host identity onto payment_transactions rows created without it" do
      # Regression: new payment_transactions rows are created without
      # host_email/host_name (only the backfill migration set them). Without a
      # snapshot at anonymisation time, nilifying user_id would lose the
      # counterparty identity required for the standalone tax record.
      user = insert(:user, email: "newhost@example.com", name: "New Host")

      pt =
        insert(:payment_transaction,
          user: user,
          host_email: nil,
          host_name: nil
        )

      assert :ok = DataRetention.anonymise_host(user.id)

      pt = Repo.reload(pt)
      assert pt.user_id == nil
      assert pt.host_email == "newhost@example.com"
      assert pt.host_name == "New Host"
      assert %DateTime{} = pt.host_deleted_at
    end

    test "does not overwrite an existing payment_transactions host snapshot" do
      # A row that already captured a snapshot (e.g. when the host's email later
      # changed) must keep its original value — COALESCE fills nulls only.
      user = insert(:user, email: "changed@example.com", name: "Changed Name")

      pt =
        insert(:payment_transaction,
          user: user,
          host_email: "original@example.com",
          host_name: "Original Name"
        )

      assert :ok = DataRetention.anonymise_host(user.id)

      pt = Repo.reload(pt)
      assert pt.host_email == "original@example.com"
      assert pt.host_name == "Original Name"
    end

    test "is idempotent — re-running does not re-stamp already anonymised rows" do
      user = insert(:user)
      insert(:connect_account, user: user)

      bp = insert(:booking_payment, host_user_id: user.id)
      pt = insert(:payment_transaction, user: user)

      assert :ok = DataRetention.anonymise_host(user.id)

      first_bp = Repo.reload(bp)
      first_pt = Repo.reload(pt)
      assert %DateTime{} = first_stamp_bp = first_bp.host_deleted_at
      assert %DateTime{} = first_stamp_pt = first_pt.host_deleted_at

      # Running again must not touch already-anonymised rows.
      assert :ok = DataRetention.anonymise_host(user.id)

      assert Repo.reload(bp).host_deleted_at == first_stamp_bp
      assert Repo.reload(pt).host_deleted_at == first_stamp_pt
    end

    test "is a no-op when the user has no payment-related rows" do
      user = insert(:user)
      assert :ok = DataRetention.anonymise_host(user.id)
    end

    test "nilifies user_id, stamps host_deleted_at, and retains the VAT document surface on captured invoices" do
      user = insert(:user)

      {:ok, invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_anonymise",
          user_id: user.id,
          subscription_id: "sub_456",
          hosted_invoice_url: "https://invoice.stripe.com/i/anonymise",
          invoice_pdf_url: "https://pay.stripe.com/invoice/anonymise/pdf"
        })

      assert :ok = DataRetention.anonymise_host(user.id)

      reloaded = Repo.get!(SubscriptionInvoiceSchema, invoice.id)

      assert reloaded.user_id == nil
      assert %DateTime{} = reloaded.host_deleted_at

      # Retained deliberately: without these the row is no longer useful for
      # the tax purpose it is kept for. See SubscriptionInvoiceQueries docs.
      assert reloaded.subscription_id == "sub_456"
      assert reloaded.hosted_invoice_url == "https://invoice.stripe.com/i/anonymise"
      assert reloaded.invoice_pdf_url == "https://pay.stripe.com/invoice/anonymise/pdf"
    end
  end
end
