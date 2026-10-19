defmodule Tymeslot.MeetingPayments.DataRetention do
  @moduledoc """
  Meeting payments' half of financial-record retention: booking payments and
  the host's Connect account. `Tymeslot.FinancialRetention` runs it together
  with `Tymeslot.Payments.DataRetention` in one transaction, and holds the
  rules for both.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries

  @doc """
  Scrubs the attendee details from every booking payment of the host's,
  keeping the host's own snapshot, and soft-deletes their Connect account.
  """
  @spec anonymise_host(integer(), DateTime.t()) :: :ok
  def anonymise_host(user_id, %DateTime{} = now) when is_integer(user_id) do
    BookingPaymentQueries.anonymise_for_host(user_id, now)
    ConnectAccountQueries.soft_delete_for_user(user_id, now)
    :ok
  end

  @doc """
  Deletes deleted hosts' booking payments dated before `cutoff`, and scrubs
  the attendee details from the rest.
  """
  @spec purge_before(DateTime.t(), DateTime.t()) :: %{
          booking_payments_deleted: non_neg_integer(),
          booking_payment_attendees_scrubbed: non_neg_integer()
        }
  def purge_before(%DateTime{} = cutoff, %DateTime{} = updated_at) do
    {deleted, _rows} = BookingPaymentQueries.delete_retained_before(cutoff)
    {scrubbed, _rows} = BookingPaymentQueries.scrub_attendees_before(cutoff, updated_at)
    %{booking_payments_deleted: deleted, booking_payment_attendees_scrubbed: scrubbed}
  end
end
