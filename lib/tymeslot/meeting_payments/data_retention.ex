defmodule Tymeslot.MeetingPayments.DataRetention do
  @moduledoc """
  Single entry point for purging a host's identifying data while retaining
  the financial records that commercial law requires us to keep, and for
  deleting those records once that period has ended.

  `anonymise_host/1` runs four writes inside a single transaction:

    * `BookingPaymentQueries.anonymise_for_host/2` — scrubs attendee PII
      (`attendee_email`, `attendee_name`, `meeting_type_name`,
      `booking_theme_id`) on every booking_payment for the host while
      retaining the host snapshot fields (`host_email`, `host_name`,
      `host_user_id`).
    * `PaymentQueries.anonymise_for_host/2` — nilifies `user_id` on
      `payment_transactions` and stamps `host_deleted_at`. Host snapshot
      fields (`host_email`, `host_name`) are retained as the
      counterparty identity required by tax law.
    * `SubscriptionInvoiceQueries.anonymise_for_host/2` — nilifies `user_id`
      and stamps `host_deleted_at` on every `subscription_invoices` row
      captured for the host. An invoice is itself a VAT document, so it is
      retained rather than deleted, but unlike `payment_transactions` the
      link is not fully broken: `subscription_id`, `hosted_invoice_url` and
      `invoice_pdf_url` are kept, since the retained document is only useful
      for its tax purpose while those remain. See the query's own docs for
      the full rationale.
    * `ConnectAccountQueries.soft_delete_for_user/2` — marks the host's
      Stripe Connect account row as `deleted`, nilifies `user_id`, and
      records `deleted_at`.

  Required for tax-record retention under EU and Swiss commercial law
  (GDPR Art. 17(3)(b) carve-out for legal-obligation retention).

  ## End of the retention period

  That carve-out lasts only as long as the obligation. `purge_expired/1`
  applies its end, and `Tymeslot.Workers.DataRetentionWorker` runs it daily.

  The period is `financial_record_years` (default 10) under
  `config :tymeslot, :payments, retention: [...]`. Commercial law generally
  counts it from the end of the financial year a record belongs to, not from
  the record's own date, so a record from 3 January and one from 30 December
  of the same year expire on the same day. `financial_year_start_month`
  (default 1, the calendar year) sets where that year begins.

  A record is dated by its own financial event, not by when its host was
  deleted: a booking payment by `paid_at` (or `inserted_at` if never paid), a
  payment transaction by `inserted_at`, an invoice by `issued_at` (or
  `inserted_at`).
  """

  alias Tymeslot.Clock
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Repo

  @retention Application.compile_env(:tymeslot, :payments, [])[:retention] || []
  @financial_record_years Keyword.get(@retention, :financial_record_years, 10)
  @financial_year_start_month Keyword.get(@retention, :financial_year_start_month, 1)

  unless is_integer(@financial_record_years) and @financial_record_years > 0 do
    raise ArgumentError,
          "financial_record_years must be a positive integer, got: " <>
            inspect(@financial_record_years)
  end

  unless @financial_year_start_month in 1..12 do
    raise ArgumentError,
          "financial_year_start_month must be 1..12, got: " <>
            inspect(@financial_year_start_month)
  end

  @type purge_counts :: %{
          booking_payments_deleted: non_neg_integer(),
          booking_payment_attendees_scrubbed: non_neg_integer(),
          payment_transactions_deleted: non_neg_integer(),
          subscription_invoices_deleted: non_neg_integer()
        }

  @spec anonymise_host(integer()) :: :ok | {:error, term()}
  def anonymise_host(user_id) when is_integer(user_id) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        BookingPaymentQueries.anonymise_for_host(user_id, now)
        PaymentQueries.anonymise_for_host(user_id, now)
        SubscriptionInvoiceQueries.anonymise_for_host(user_id, now)
        ConnectAccountQueries.soft_delete_for_user(user_id, now)
        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies the end of the statutory retention period to every financial record
  dated before `retention_cutoff/1` for `now`'s date.

    * Deleted hosts' booking payments, payment transactions and captured
      invoices are deleted. For an invoice that removes only Tymeslot's copy;
      the document Stripe hosts is untouched.
    * Booking payments of hosts who still exist keep their row, but lose the
      attendee's name and email.

  Returns how many rows each step touched.
  """
  @spec purge_expired(DateTime.t()) :: {:ok, purge_counts()} | {:error, term()}
  def purge_expired(now \\ Clock.utc_now()) do
    cutoff = retention_cutoff(DateTime.to_date(now))
    updated_at = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      {booking_payments, _rows} = BookingPaymentQueries.delete_retained_before(cutoff)
      {attendees, _rows} = BookingPaymentQueries.scrub_attendees_before(cutoff, updated_at)
      {transactions, _rows} = PaymentQueries.delete_retained_before(cutoff)
      {invoices, _rows} = SubscriptionInvoiceQueries.delete_retained_before(cutoff)

      %{
        booking_payments_deleted: booking_payments,
        booking_payment_attendees_scrubbed: attendees,
        payment_transactions_deleted: transactions,
        subscription_invoices_deleted: invoices
      }
    end)
  end

  @doc """
  The instant before which a financial record's retention period has ended on
  `today`: the start of the most recent financial year that began at least
  `years` years ago. A record dated before it belongs to a financial year that
  closed `years` or more years ago.

  With the defaults (ten years, calendar financial year), a record from 2026
  is kept until its year has closed ten years ago: on 31 December 2036 the
  cutoff is 1 January 2026, so it is kept, and from 1 January 2037 the cutoff
  is 1 January 2027, so it is past its period.
  """
  @spec retention_cutoff(Date.t(), pos_integer(), 1..12) :: DateTime.t()
  def retention_cutoff(
        %Date{} = today,
        years \\ @financial_record_years,
        start_month \\ @financial_year_start_month
      ) do
    reference = Date.shift(today, year: -years)
    year_start = Date.new!(reference.year, start_month, 1)

    year_start =
      if Date.after?(year_start, reference),
        do: Date.shift(year_start, year: -1),
        else: year_start

    DateTime.new!(year_start, ~T[00:00:00], "Etc/UTC")
  end
end
