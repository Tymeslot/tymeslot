defmodule TymeslotWeb.Dashboard.PaymentsSettings.PaymentsTable do
  @moduledoc """
  Recent-payments table.

  Stateless function component rendered by `PaymentsSettingsComponent`. Lists
  the host's payments with amount and status, and shows a Refund button for
  each refundable payment while the connect account is not soft-deleted. The
  button dispatches `open_refund_modal` back to the parent component
  (`@myself`). Owns the status-label formatting and the refund-visibility
  predicates.
  """

  use TymeslotWeb, :html

  alias Tymeslot.MeetingPayments

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payments, :list, required: true
  attr :account, :map, required: true
  attr :myself, :any, required: true

  @spec payments_table(map()) :: Phoenix.LiveView.Rendered.t()
  def payments_table(assigns) do
    ~H"""
    <.detail_card title="Recent payments">
      <p :if={@payments == []} class="text-tymeslot-500">No payments yet.</p>
      <div :if={@payments != []} class="overflow-x-auto">
        <table class="w-full">
        <thead class="text-left text-token-sm text-tymeslot-500 border-b border-tymeslot-100">
          <tr>
            <th class="p-2">Date</th>
            <th class="p-2">Attendee</th>
            <th class="p-2">Meeting type</th>
            <th class="p-2 text-right">Amount</th>
            <th class="p-2">Status</th>
            <th class="p-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @payments} class="border-b border-tymeslot-50">
            <td class="p-2 text-token-sm">{Calendar.strftime(p.inserted_at, "%-d %b %Y")}</td>
            <td class="p-2 text-token-sm">{p.attendee_email}</td>
            <td class="p-2 text-token-sm">{p.meeting_type_name}</td>
            <td class="p-2 text-token-sm text-right">
              {format_amount(p.amount_cents, p.currency)}
            </td>
            <td class="p-2 text-token-sm">{format_status(p.status)}</td>
            <td class="p-2 text-right">
              <button
                :if={MeetingPayments.refundable?(p) and not connect_account_deleted?(@account)}
                type="button"
                class="text-token-sm text-turquoise-700 font-semibold underline"
                phx-click="open_refund_modal"
                phx-value-id={p.id}
                phx-target={@myself}
              >
                Refund
              </button>
            </td>
          </tr>
        </tbody>
        </table>
      </div>
    </.detail_card>
    """
  end

  defp connect_account_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp connect_account_deleted?(_account), do: false

  defp format_status("paid"), do: "Paid"
  defp format_status("partially_refunded"), do: "Partially refunded"
  defp format_status("refunded"), do: "Refunded"
  defp format_status("disputed"), do: "Disputed"
  defp format_status("pending"), do: "Pending"
  defp format_status("failed"), do: "Failed"
  defp format_status(other), do: other
end
