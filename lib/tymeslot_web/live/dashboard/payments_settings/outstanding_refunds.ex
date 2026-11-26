defmodule TymeslotWeb.Dashboard.PaymentsSettings.OutstandingRefunds do
  @moduledoc """
  Cancelled, declined and expired bookings whose money the host still holds.

  Stateless function component rendered by `PaymentsSettingsComponent` at the
  top of the payments screen, and only when there is something to show.

  It exists because the recent-payments table cannot answer this question: it
  renders payment status without meeting status, so an unrefunded cancellation
  is indistinguishable there from a booking that is still going ahead, and its
  25-row window drops the older ones off the screen entirely. A cancellation
  never refunds on its own, and when the attendee is the one who cancelled no
  refund is even offered, so without this card the money can sit unnoticed.

  An expired booking here was paid for but never confirmed: its payment
  arrived after the slot was taken, or it was a paid request that lapsed
  unapproved. Those refund automatically, so such a row is one whose refund
  has not gone through (yet). A declined request is stored as a cancelled
  meeting, but it too refunds on its own (`Approval.refunds_on_release?/1`),
  synchronously as the host declines, so a declined row is one whose
  automatic refund failed; it must not be told that cancelling never
  refunds. A request that was a confirmed meeting before a reschedule sent
  it back for approval is the exception: declining it refunds nothing, so it
  reads as a cancellation. The card explains each kind it lists in its own
  words, and dates an expired row by its payment, since an expired meeting
  carries no cancellation date. A paid seat its participant cancelled reads
  as a cancellation, dated by when the participant left.

  A row whose refund is recorded and still pending stays listed, owed until
  it settles: with the pending amount noted beside the row's action while
  some of the balance is left to refund, and a "Refund processing" badge
  in place of any action once the pending refunds hold all of it. Rows
  offer the same `open_refund_modal` event as the payments table. A row
  only carries that button when both halves of the question say yes: the
  payment itself is still refundable (`MeetingPayments.refundable?/1`
  covers balance, age and dispute state), *and* the host still has a live
  Connect account to refund from. Any other row with a balance beyond its
  pending refunds gets the "Refund in Stripe" label instead, and stays
  listed, because the debt is real either way.

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
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingState
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
        <p
          :if={Enum.any?(@payments, &(kind(&1) == :cancelled))}
          class="text-token-sm text-tymeslot-700 mb-4"
        >
          {dgettext(
            "dashboard_payments",
            "These bookings were cancelled while you still held the attendee's money. Cancelling never refunds on its own."
          )}
        </p>
        <p
          :if={Enum.any?(@payments, &(kind(&1) == :declined))}
          class="text-token-sm text-tymeslot-700 mb-4"
        >
          {dgettext(
            "dashboard_payments",
            "You declined these bookings, but their automatic refund didn't go through. Refund them here or in Stripe."
          )}
        </p>
        <p
          :if={Enum.any?(@payments, &(kind(&1) == :expired))}
          class="text-token-sm text-tymeslot-700 mb-4"
        >
          {dgettext(
            "dashboard_payments",
            "Expired bookings were paid for but never confirmed, for example because the payment arrived after the slot was taken. Their refund is issued automatically; if one is still listed later, refund it here or in Stripe."
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
                <th class="p-2">{dgettext("dashboard_payments", "Date")}</th>
                <th class="p-2">{dgettext("dashboard_payments", "Attendee")}</th>
                <th class="p-2">{dgettext("dashboard_payments", "Meeting type")}</th>
                <th class="p-2 text-right">{dgettext("dashboard_payments", "Outstanding")}</th>
                <th class="p-2"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={p <- @payments}
                id={"outstanding-refund-#{p.id}"}
                class="border-b border-tymeslot-50"
              >
                <td class="p-2 text-token-sm">{format_date_cell(p)}</td>
                <td class="p-2 text-token-sm">{p.attendee_email}</td>
                <td class="p-2 text-token-sm">{p.meeting_type_name}</td>
                <td class="p-2 text-token-sm text-right font-semibold">
                  {format_amount(MeetingPayments.refund_owed_cents(p), p.currency)}
                </td>
                <td class="p-2 text-right">
                  <.pill :if={row_action(p, @account) == :processing} tone={:neutral} size={:sm}>
                    {dgettext("dashboard_payments", "Refund processing")}
                  </.pill>
                  <span
                    :if={
                      row_action(p, @account) != :processing and MeetingPayments.refund_pending?(p)
                    }
                    class="text-token-xs text-tymeslot-500 mr-2"
                  >
                    {dgettext("dashboard_payments", "%{amount} being processed",
                      amount: format_amount(MeetingPayments.pending_refund_cents(p), p.currency)
                    )}
                  </span>
                  <.action_button
                    :if={row_action(p, @account) == :refund}
                    variant={:secondary}
                    size={:sm}
                    phx-click="open_refund_modal"
                    phx-value-id={p.id}
                    phx-target={@myself}
                  >
                    {dgettext("dashboard_payments", "Refund")}
                  </.action_button>
                  <span
                    :if={row_action(p, @account) == :in_stripe}
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

  # Pending refunds that hold all that is owed are Tymeslot's to finish.
  # Otherwise the in-app Refund button needs two independent questions
  # answered yes: whether the payment can still be refunded at all, and
  # whether there is a Connect account left to refund it from. A balance
  # beyond the pending refunds that fails either is the host's to settle in
  # Stripe, however much of it is pending.
  defp row_action(payment, account) do
    cond do
      all_pending?(payment) -> :processing
      MeetingPayments.refundable?(payment) and connected_for_refunds?(account) -> :refund
      true -> :in_stripe
    end
  end

  defp all_pending?(payment) do
    MeetingPayments.refund_pending?(payment) and
      MeetingPayments.pending_refund_cents(payment) >= MeetingPayments.refund_owed_cents(payment)
  end

  # Nil is the live case, not an oversight: `disconnect/1` nulls `user_id` on
  # the row it soft-deletes, so after a disconnect nothing user-scoped can
  # find the account and the parent has nothing to pass. The soft-deleted
  # shape is matched too, for the reconnect window where a stale assign could
  # still carry one.
  defp connected_for_refunds?(nil), do: false
  defp connected_for_refunds?(%{deleted_at: %DateTime{}}), do: false
  defp connected_for_refunds?(_account), do: true

  # Which explanation a row needs: an expired or declined booking refunds on
  # its own, a cancelled one never does.
  defp kind(%{meeting: meeting}) do
    cond do
      MeetingState.expired?(meeting) -> :expired
      Approval.declined?(meeting) and Approval.refunds_on_release?(meeting) -> :declined
      true -> :cancelled
    end
  end

  # A seat paid for but never booked (refused at checkout, its slot full
  # say) is dated by its payment: the session it was held on may go ahead.
  defp format_date_cell(%{
         seat_payment: true,
         participant_id: nil,
         paid_at: %DateTime{} = paid_at
       }),
       do:
         dgettext("dashboard_payments", "Not booked, paid %{on_date}", on_date: on_date(paid_at))

  # A seat its participant cancelled is dated by when they left: the session
  # itself may still be going ahead.
  defp format_date_cell(%{participant: %{cancelled_at: %DateTime{} = left_at}}),
    do: dgettext("dashboard_payments", "Left %{on_date}", on_date: on_date(left_at))

  # An expired meeting carries no cancellation date, so its row is dated by
  # the payment. A cancelled meeting always carries `cancelled_at`, and an
  # expired payment `paid_at`, so the bare fallbacks should not arise; they
  # are tolerated rather than raising, because a vaguer cell beats a 500 on
  # the payments screen.
  defp format_date_cell(%{meeting: %{status: _status} = meeting} = payment) do
    if MeetingState.expired?(meeting),
      do: expired_date_cell(payment),
      else: released_date_cell(meeting)
  end

  defp format_date_cell(_payment), do: ""

  defp expired_date_cell(%{paid_at: %DateTime{} = paid_at}),
    do: dgettext("dashboard_payments", "Expired, paid %{on_date}", on_date: on_date(paid_at))

  defp expired_date_cell(_payment), do: dgettext("dashboard_payments", "Expired")

  defp released_date_cell(%{cancelled_at: %DateTime{} = cancelled_at} = meeting) do
    if Approval.declined?(meeting),
      do: dgettext("dashboard_payments", "Declined %{on_date}", on_date: on_date(cancelled_at)),
      else: dgettext("dashboard_payments", "Cancelled %{on_date}", on_date: on_date(cancelled_at))
  end

  defp released_date_cell(_meeting), do: ""

  defp on_date(%DateTime{} = datetime) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    datetime
    |> LocaleFormat.format_short_date_with_year(locale)
    |> LocaleFormat.with_article(:none, locale)
  end
end
