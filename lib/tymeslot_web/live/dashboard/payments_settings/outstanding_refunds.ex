defmodule TymeslotWeb.Dashboard.PaymentsSettings.OutstandingRefunds do
  @moduledoc """
  Cancelled bookings whose money the host still holds.

  Stateless function component rendered by `PaymentsSettingsComponent` above
  the recent-payments table, and only when there is something to show.

  It exists because the recent-payments table cannot answer this question: it
  renders payment status without meeting status, so an unrefunded cancellation
  is indistinguishable there from a booking that is still going ahead, and its
  25-row window drops the older ones off the screen entirely. A cancellation
  never refunds on its own, and when the attendee is the one who cancelled no
  refund is even offered, so without this card the money can sit unnoticed.

  Each row offers the same `open_refund_modal` event as the payments table.
  Rows past the 60-day window carry no button, because
  `MeetingPayments.refundable?/1` is false for them and only the host's Stripe
  dashboard can settle them; they stay listed so the debt is still visible.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Helpers.LocaleFormat

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payments, :list, required: true
  attr :account, :map, required: true
  attr :myself, :any, required: true

  @spec outstanding_refunds(map()) :: Phoenix.LiveView.Rendered.t()
  def outstanding_refunds(assigns) do
    ~H"""
    <div :if={@payments != []} id="outstanding-refunds">
      <.detail_card title={dgettext("dashboard_payments", "Refunds outstanding")}>
        <p class="text-token-sm text-tymeslot-700 mb-4">
          {dgettext(
            "dashboard_payments",
            "These bookings were cancelled while you still held the attendee's money. Cancelling never refunds on its own."
          )}
        </p>
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="text-left text-token-sm text-tymeslot-500 border-b border-tymeslot-100">
              <tr>
                <th class="p-2">{dgettext("dashboard_payments", "Cancelled")}</th>
                <th class="p-2">{dgettext("dashboard_payments", "Attendee")}</th>
                <th class="p-2">{dgettext("dashboard_payments", "Meeting type")}</th>
                <th class="p-2 text-right">{dgettext("dashboard_payments", "Outstanding")}</th>
                <th class="p-2"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @payments} class="border-b border-tymeslot-50">
                <td class="p-2 text-token-sm">{format_cancelled_at(p.meeting)}</td>
                <td class="p-2 text-token-sm">{p.attendee_email}</td>
                <td class="p-2 text-token-sm">{p.meeting_type_name}</td>
                <td class="p-2 text-token-sm text-right font-semibold">
                  {format_amount(MeetingPayments.refundable_remaining_cents(p), p.currency)}
                </td>
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
                  <span
                    :if={not MeetingPayments.refundable?(p)}
                    class="text-token-xs text-tymeslot-500"
                  >
                    {dgettext("dashboard_payments", "Refund in Stripe")}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.detail_card>
    </div>
    """
  end

  defp connect_account_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp connect_account_deleted?(_account), do: false

  # A cancelled meeting always carries `cancelled_at`, so the fallback should
  # not arise; it is tolerated rather than raising, because an empty cell beats
  # a 500 on the payments screen.
  defp format_cancelled_at(%{cancelled_at: %DateTime{} = cancelled_at}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    month = LocaleFormat.format_month_name(cancelled_at.month, locale, :short)
    "#{cancelled_at.day} #{month} #{cancelled_at.year}"
  end

  defp format_cancelled_at(_meeting), do: ""
end
