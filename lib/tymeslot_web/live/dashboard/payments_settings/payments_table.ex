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
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Helpers.LocaleFormat

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payments, :list, required: true
  attr :account, :map, required: true
  attr :myself, :any, required: true

  @spec payments_table(map()) :: Phoenix.LiveView.Rendered.t()
  def payments_table(assigns) do
    ~H"""
    <.detail_card title={dgettext("dashboard_payments", "Recent payments")}>
      <p :if={@payments == []} class="text-tymeslot-500">
        {dgettext("dashboard_payments", "No payments yet.")}
      </p>
      <div :if={@payments != []} class="overflow-x-auto">
        <table class="w-full">
          <thead class="text-left text-token-sm text-tymeslot-500 border-b border-tymeslot-100">
            <tr>
              <th class="p-2">{dgettext("dashboard_payments", "Date")}</th>
              <th class="p-2">{dgettext("dashboard_payments", "Attendee")}</th>
              <th class="p-2">{dgettext("dashboard_payments", "Meeting type")}</th>
              <th class="p-2 text-right">{dgettext("dashboard_payments", "Amount")}</th>
              <th class="p-2">{dgettext("dashboard_payments", "Status")}</th>
              <th class="p-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @payments} class="border-b border-tymeslot-50">
              <td class="p-2 text-token-sm">{format_payment_date(p.inserted_at)}</td>
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
                  {dgettext("dashboard_payments", "Refund")}
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

  defp format_payment_date(inserted_at) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    month = LocaleFormat.format_month_name(inserted_at.month, locale, :short)
    "#{inserted_at.day} #{month} #{inserted_at.year}"
  end

  defp format_status("paid"), do: dgettext("dashboard_payments", "Paid")

  defp format_status("partially_refunded"),
    do: dgettext("dashboard_payments", "Partially refunded")

  defp format_status("refunded"), do: dgettext("dashboard_payments", "Refunded")
  defp format_status("disputed"), do: dgettext("dashboard_payments", "Disputed")
  defp format_status("pending"), do: dgettext("dashboard_payments", "Pending")
  defp format_status("failed"), do: dgettext("dashboard_payments", "Failed")
  defp format_status(other), do: other
end
