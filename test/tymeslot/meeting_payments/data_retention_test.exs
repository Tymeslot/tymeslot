defmodule Tymeslot.MeetingPayments.DataRetentionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.DataRetention
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionInvoiceSchema

  # The default period is ten years from the end of the calendar year, so the
  # records of 2026 are the last ones kept on 31 December 2036 and the first
  # ones past their period on 1 January 2037.
  @last_day_kept ~U[2036-12-31 23:59:59Z]
  @first_day_purged ~U[2037-01-01 00:00:00Z]
  @end_of_2026 ~U[2026-12-31 23:59:59Z]
  @start_of_2027 ~U[2027-01-01 00:00:00Z]

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

  describe "retention_cutoff/3" do
    test "is the start of the calendar year that began ten years ago, by default" do
      assert DataRetention.retention_cutoff(~D[2036-12-31]) == ~U[2026-01-01 00:00:00Z]
      assert DataRetention.retention_cutoff(~D[2037-01-01]) == ~U[2027-01-01 00:00:00Z]
      assert DataRetention.retention_cutoff(~D[2037-12-31]) == ~U[2027-01-01 00:00:00Z]
    end

    test "follows a financial year that starts mid-year" do
      # An April-to-March year, kept seven years: the year ending 31 March
      # 2027 closes seven years later on 31 March 2034.
      assert DataRetention.retention_cutoff(~D[2034-03-31], 7, 4) == ~U[2026-04-01 00:00:00Z]
      assert DataRetention.retention_cutoff(~D[2034-04-01], 7, 4) == ~U[2027-04-01 00:00:00Z]
    end

    test "handles a leap day" do
      assert DataRetention.retention_cutoff(~D[2036-02-29]) == ~U[2026-01-01 00:00:00Z]
    end
  end

  describe "purge_expired/1 for deleted hosts" do
    test "deletes a booking payment once the year it was paid in closed ten years ago" do
      expired = retained_booking_payment(paid_at: @end_of_2026)
      current = retained_booking_payment(paid_at: @start_of_2027)

      assert {:ok, %{booking_payments_deleted: 1}} =
               DataRetention.purge_expired(@first_day_purged)

      refute Repo.reload(expired)
      assert Repo.reload(current)
    end

    test "counts from the end of the year, so January and December rows expire together" do
      january = retained_booking_payment(paid_at: ~U[2026-01-03 10:00:00Z])
      december = retained_booking_payment(paid_at: ~U[2026-12-30 10:00:00Z])

      assert {:ok, %{booking_payments_deleted: 0}} = DataRetention.purge_expired(@last_day_kept)
      assert Repo.reload(january)
      assert Repo.reload(december)

      assert {:ok, %{booking_payments_deleted: 2}} =
               DataRetention.purge_expired(@first_day_purged)

      refute Repo.reload(january)
      refute Repo.reload(december)
    end

    test "dates a never-paid booking payment by when it was created" do
      unpaid = retained_booking_payment(paid_at: nil, inserted_at: @end_of_2026)

      assert {:ok, _counts} = DataRetention.purge_expired(@first_day_purged)

      refute Repo.reload(unpaid)
    end

    test "deletes a payment transaction once its year closed ten years ago" do
      expired = retained_transaction(@end_of_2026)
      current = retained_transaction(@start_of_2027)

      assert {:ok, %{payment_transactions_deleted: 1}} =
               DataRetention.purge_expired(@first_day_purged)

      refute Repo.get(PaymentTransactionSchema, expired.id)
      assert Repo.get(PaymentTransactionSchema, current.id)
    end

    test "deletes a captured invoice once the year it was issued in closed ten years ago" do
      expired = retained_invoice(issued_at: @end_of_2026)
      current = retained_invoice(issued_at: @start_of_2027)
      undated = retained_invoice(issued_at: nil, inserted_at: @end_of_2026)

      assert {:ok, %{subscription_invoices_deleted: 2}} =
               DataRetention.purge_expired(@first_day_purged)

      refute Repo.get(SubscriptionInvoiceSchema, expired.id)
      refute Repo.get(SubscriptionInvoiceSchema, undated.id)
      assert Repo.get(SubscriptionInvoiceSchema, current.id)
    end
  end

  describe "purge_expired/1 for hosts who still exist" do
    test "scrubs the attendee from an expired booking payment but keeps the row" do
      user = insert(:user)

      expired =
        insert(:paid_booking_payment,
          host_user_id: user.id,
          host_email: "host@example.com",
          paid_at: @end_of_2026
        )

      current = insert(:paid_booking_payment, host_user_id: user.id, paid_at: @start_of_2027)

      assert {:ok, %{booking_payment_attendees_scrubbed: 1, booking_payments_deleted: 0}} =
               DataRetention.purge_expired(@first_day_purged)

      scrubbed = Repo.reload(expired)
      assert is_nil(scrubbed.attendee_email)
      assert is_nil(scrubbed.attendee_name)
      assert scrubbed.host_email == "host@example.com"
      assert scrubbed.amount_cents == expired.amount_cents

      untouched = Repo.reload(current)
      assert untouched.attendee_email == current.attendee_email
      assert untouched.attendee_name == current.attendee_name
    end

    test "keeps an existing account's payment transactions and invoices, however old" do
      user = insert(:user)

      transaction =
        insert(:payment_transaction, user: user, inserted_at: ~U[2015-03-01 00:00:00Z])

      invoice =
        Repo.insert!(%SubscriptionInvoiceSchema{
          stripe_invoice_id: "in_live_host",
          user_id: user.id,
          issued_at: ~U[2015-03-01 00:00:00Z]
        })

      assert {:ok, %{payment_transactions_deleted: 0, subscription_invoices_deleted: 0}} =
               DataRetention.purge_expired(@first_day_purged)

      assert Repo.get(PaymentTransactionSchema, transaction.id)
      assert Repo.get(SubscriptionInvoiceSchema, invoice.id)
    end
  end

  # A booking payment as `anonymise_host/1` leaves it.
  defp retained_booking_payment(fields) do
    insert(
      :paid_booking_payment,
      [attendee_email: nil, attendee_name: nil, host_deleted_at: ~U[2030-05-01 00:00:00Z]] ++
        fields
    )
  end

  defp retained_transaction(inserted_at) do
    insert(:payment_transaction,
      user: nil,
      host_email: "gone@example.com",
      host_deleted_at: ~U[2030-05-01 00:00:00Z],
      inserted_at: inserted_at
    )
  end

  defp retained_invoice(fields) do
    Repo.insert!(
      struct!(
        SubscriptionInvoiceSchema,
        [
          stripe_invoice_id: "in_#{System.unique_integer([:positive])}",
          host_deleted_at: ~U[2030-05-01 00:00:00Z]
        ] ++ fields
      )
    )
  end
end
