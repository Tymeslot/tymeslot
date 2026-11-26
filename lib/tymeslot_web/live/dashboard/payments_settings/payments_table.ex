defmodule TymeslotWeb.Dashboard.PaymentsSettings.PaymentsTable do
  @moduledoc """
  Recent-payments table.

  Stateless function component rendered by `PaymentsSettingsComponent`. Lists
  the host's payments with amount and status, and shows a Refund button for
  each refundable payment while the connect account is not soft-deleted. A
  seat payment of a group session names the session, and how many seats it
  paid for when more than one. The
  button dispatches `open_refund_modal` back to the parent component
  (`@myself`). Owns the status-label formatting and the refund-visibility
  predicates.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payments, :list, required: true
  attr :account, :map, required: true
  attr :timezone, :string, default: "Etc/UTC", doc: "the host's, for a session's start"
  attr :time_format, :string, default: "24h", doc: "the host's clock format"
  attr :myself, :any, required: true

  @spec payments_table(map()) :: Phoenix.LiveView.Rendered.t()
  def payments_table(assigns) do
    ~H"""
    <.detail_card title={dgettext("dashboard_payments", "Recent payments")}>
      <p :if={@payments == []} class="text-tymeslot-500">
        {dgettext("dashboard_payments", "No payments yet.")}
      </p>
      <div :if={@payments != []} class="overflow-x-auto">
        <table class="w-full" data-testid="payments-table">
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
              <td class="p-2 text-token-sm">{meeting_type_cell(p, @timezone, @time_format)}</td>
              <td class="p-2 text-token-sm text-right">
                {format_amount(p.amount_cents, p.currency)}
                <span
                  :if={seats(p) > 1}
                  class="block text-token-xs text-tymeslot-500"
                  data-testid="payment-seats"
                >
                  {dngettext("dashboard_payments", "%{count} seat", "%{count} seats", seats(p))}
                </span>
              </td>
              <td class="p-2 text-token-sm">{format_status(p.status)}</td>
              <td class="p-2 text-right">
                <.action_button
                  :if={MeetingPayments.refundable?(p) and not connect_account_deleted?(@account)}
                  variant={:secondary}
                  size={:sm}
                  phx-click="open_refund_modal"
                  phx-value-id={p.id}
                  phx-target={@myself}
                >
                  {dgettext("dashboard_payments", "Refund")}
                </.action_button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.detail_card>
    """
  end

  # A seat payment is one of several for a group session, so its row names
  # the session too: its meeting type and when it starts, in the host's zone
  # and clock. A session since deleted leaves the type alone.
  defp meeting_type_cell(
         %{seat_payment: true, meeting: %MeetingSchema{start_time: start_time}} = payment,
         timezone,
         time_format
       ) do
    dgettext("dashboard_payments", "%{type} · %{date}",
      type: payment.meeting_type_name,
      date: session_start(start_time, timezone, time_format)
    )
  end

  defp meeting_type_cell(payment, _timezone, _time_format), do: payment.meeting_type_name

  defp session_start(start_time, timezone, time_format) do
    date = start_time |> DashboardFormat.local_date(timezone) |> DashboardFormat.short_date()
    "#{date}, #{DashboardFormat.clock(start_time, timezone, time_format)}"
  end

  defp seats(%{seat_payment: true, seats: seats}) when is_integer(seats), do: seats
  defp seats(_payment), do: 1

  defp connect_account_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp connect_account_deleted?(_account), do: false

  defp format_payment_date(inserted_at) do
    LocaleFormat.format_short_date_with_year(inserted_at, Gettext.get_locale(TymeslotWeb.Gettext))
  end

  defp format_status(:paid), do: dgettext("dashboard_payments", "Paid")

  defp format_status(:partially_refunded),
    do: dgettext("dashboard_payments", "Partially refunded")

  defp format_status(:refunded), do: dgettext("dashboard_payments", "Refunded")
  defp format_status(:disputed), do: dgettext("dashboard_payments", "Disputed")
  defp format_status(:pending), do: dgettext("dashboard_payments", "Pending")
  defp format_status(:failed), do: dgettext("dashboard_payments", "Failed")
end
