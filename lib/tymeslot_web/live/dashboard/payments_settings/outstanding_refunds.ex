defmodule TymeslotWeb.Dashboard.PaymentsSettings.OutstandingRefunds do
  @moduledoc """
  Cancelled bookings whose money the host still holds.

  Stateless function component rendered by `PaymentsSettingsComponent` at the
  top of the payments screen, and only when there is something to show.

  It exists because the recent-payments table cannot answer this question: it
  renders payment status without meeting status, so an unrefunded cancellation
  is indistinguishable there from a booking that is still going ahead, and its
  25-row window drops the older ones off the screen entirely. A cancellation
  never refunds on its own, and when the attendee is the one who cancelled no
  refund is even offered, so without this card the money can sit unnoticed.

  Each row offers the same `open_refund_modal` event as the payments table.
  A row only carries that button when both halves of the question say yes:
  the payment itself is still refundable (`MeetingPayments.refundable?/1`
  covers balance, age and dispute state), *and* the host still has a live
  Connect account to refund from. Everything else gets the "Refund in Stripe"
  label instead, and stays listed, because the debt is real either way.

  `@account` is therefore nilable. It is nil for a host who has disconnected
  Stripe, which is exactly when this card matters most: the soft delete
  detaches the row from the user, so there is no deleted account to be handed
  here, only its absence. The card renders above the Connect call-to-action so
  such a host sees what they still owe before the prompt to reconnect.

  `@total_count` is the unbounded count behind `@payments`, which is a bounded
  window; when it is larger the card says so rather than truncating silently.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Helpers.LocaleFormat

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payments, :list, required: true
  attr :total_count, :integer, required: true
  attr :account, :map, default: nil
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
        <.info_box :if={not connected_for_refunds?(@account)} variant={:warning} class="mb-4">
          {dgettext(
            "dashboard_payments",
            "Your Stripe account is not connected, so these refunds have to be issued from your Stripe dashboard. The money is still owed."
          )}
        </.info_box>
        <p :if={@total_count > length(@payments)} class="text-token-sm text-tymeslot-500 mb-4">
          {dgettext(
            "dashboard_payments",
            "Showing the %{shown} oldest of %{total} outstanding refunds.",
            shown: length(@payments),
            total: @total_count
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
                    :if={can_refund_here?(p, @account)}
                    type="button"
                    class="text-token-sm text-turquoise-700 font-semibold underline"
                    phx-click="open_refund_modal"
                    phx-value-id={p.id}
                    phx-target={@myself}
                  >
                    {dgettext("dashboard_payments", "Refund")}
                  </button>
                  <span
                    :if={not can_refund_here?(p, @account)}
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

  # Two independent questions, and the in-app Refund button needs both
  # answered yes: whether the payment can still be refunded at all, and
  # whether there is a Connect account left to refund it from.
  defp can_refund_here?(payment, account),
    do: MeetingPayments.refundable?(payment) and connected_for_refunds?(account)

  # Nil is the live case, not an oversight: `disconnect/1` nulls `user_id` on
  # the row it soft-deletes, so after a disconnect nothing user-scoped can
  # find the account and the parent has nothing to pass. The soft-deleted
  # shape is matched too, for the reconnect window where a stale assign could
  # still carry one.
  defp connected_for_refunds?(nil), do: false
  defp connected_for_refunds?(%{deleted_at: %DateTime{}}), do: false
  defp connected_for_refunds?(_account), do: true

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
