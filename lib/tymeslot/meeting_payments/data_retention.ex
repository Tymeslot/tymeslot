defmodule Tymeslot.MeetingPayments.DataRetention do
  @moduledoc """
  Single entry point for purging a host's identifying data while retaining
  the financial records that EU and Swiss commercial law require us to
  keep (typically up to ten years).

  `anonymise_host/1` runs three writes inside a single transaction:

    * `BookingPaymentQueries.anonymise_for_host/2` — scrubs attendee PII
      (`attendee_email`, `attendee_name`, `meeting_type_name`,
      `booking_theme_id`) on every booking_payment for the host while
      retaining the host snapshot fields (`host_email`, `host_name`,
      `host_user_id`).
    * `PaymentQueries.anonymise_for_host/2` — nilifies `user_id` on
      `payment_transactions` and stamps `host_deleted_at`. Host snapshot
      fields (`host_email`, `host_name`) are retained as the
      counterparty identity required by tax law.
    * `ConnectAccountQueries.soft_delete_for_user/2` — marks the host's
      Stripe Connect account row as `deleted`, nilifies `user_id`, and
      records `deleted_at`.

  Required for tax-record retention under EU and Swiss commercial law
  (GDPR Art. 17(3)(b) carve-out for legal-obligation retention).
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Repo

  @spec anonymise_host(integer()) :: :ok | {:error, term()}
  def anonymise_host(user_id) when is_integer(user_id) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        BookingPaymentQueries.anonymise_for_host(user_id, now)
        PaymentQueries.anonymise_for_host(user_id, now)
        ConnectAccountQueries.soft_delete_for_user(user_id, now)
        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
