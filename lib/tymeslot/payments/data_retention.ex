defmodule Tymeslot.Payments.DataRetention do
  @moduledoc """
  The platform's half of financial-record retention: subscription payment
  transactions and captured invoices. `Tymeslot.FinancialRetention` runs it
  together with `Tymeslot.MeetingPayments.DataRetention` in one
  transaction, and holds the rules for both.
  """

  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.SubscriptionInvoiceQueries

  @doc """
  Unlinks the host from their payment transactions and captured invoices,
  which are kept as the tax records they are.
  """
  @spec anonymise_host(integer(), DateTime.t()) :: :ok
  def anonymise_host(user_id, %DateTime{} = now) when is_integer(user_id) do
    PaymentQueries.anonymise_for_host(user_id, now)
    SubscriptionInvoiceQueries.anonymise_for_host(user_id, now)
    :ok
  end

  @doc """
  Deletes deleted hosts' payment transactions and captured invoices dated
  before `cutoff`.
  """
  @spec purge_before(DateTime.t()) :: %{
          payment_transactions_deleted: non_neg_integer(),
          subscription_invoices_deleted: non_neg_integer()
        }
  def purge_before(%DateTime{} = cutoff) do
    {transactions, _rows} = PaymentQueries.delete_retained_before(cutoff)
    {invoices, _rows} = SubscriptionInvoiceQueries.delete_retained_before(cutoff)
    %{payment_transactions_deleted: transactions, subscription_invoices_deleted: invoices}
  end
end
