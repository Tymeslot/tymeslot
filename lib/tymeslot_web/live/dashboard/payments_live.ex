defmodule TymeslotWeb.Dashboard.PaymentsLive do
  @moduledoc """
  Host-facing payments dashboard.

  Surfaces the Stripe Connect onboarding state, recent payments,
  lifetime totals, and the disconnect flow. The whole page is gated
  behind the `:meeting_payments` feature flag.
  """

  use TymeslotWeb, :live_view

  alias Tymeslot.Features
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccounts

  @refund_window_days 60

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Features.check_access(user.id, :meeting_payments) do
      :ok ->
        {:ok,
         socket
         |> assign(:page_title, "Payments")
         |> assign_payments_state(user)}

      {:error, :insufficient_plan} ->
        {:ok,
         socket
         |> put_flash(:error, "Meeting payments require an upgraded plan.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Meeting payments are not available on this instance.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <h1 class="display-md mb-6">Payments</h1>

      <%= if is_nil(@connect_account) do %>
        <.connect_cta />
      <% else %>
        <.status_card account={@connect_account} />
        <.payments_table payments={@payments} />
        <.lifetime_stats stats={@stats} />
        <.disconnect_zone />
      <% end %>
    </div>
    """
  end

  defp assign_payments_state(socket, user) do
    account = ConnectAccountQueries.live_for_user(user.id)
    payments = BookingPaymentQueries.for_host(user.id)
    stats = BookingPaymentQueries.lifetime_stats(user.id)

    socket
    |> assign(:connect_account, account)
    |> assign(:payments, payments)
    |> assign(:stats, stats)
  end

  defp connect_cta(assigns) do
    ~H"""
    <div class="rounded-token-lg border border-tymeslot-200 bg-white p-6">
      <h2 class="display-md mb-2">Connect Stripe</h2>
      <p class="text-tymeslot-700 mb-4">
        Connect Stripe to start charging for meetings. Money goes directly
        to your Stripe account.
      </p>
      <form action={~p"/dashboard/payments/connect"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.action_button type="submit" variant={:primary}>Connect Stripe</.action_button>
      </form>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("disconnect", _params, socket) do
    user = socket.assigns.current_user
    :ok = ConnectAccounts.disconnect(user)

    {:noreply,
     socket
     |> put_flash(:info, "Stripe disconnected.")
     |> assign_payments_state(user)}
  end

  defp status_card(assigns) do
    state = status_state(assigns.account)
    assigns = assign(assigns, :state, state)

    ~H"""
    <div class={"rounded-token-lg border p-6 mb-6 #{state_classes(@state)}"}>
      <div class="flex items-center justify-between gap-4">
        <div>
          <h2 class="display-md">{state_title(@state)}</h2>
          <p class="text-tymeslot-700 mt-1">{state_message(@account, @state)}</p>
        </div>
      </div>
    </div>
    """
  end

  defp payments_table(assigns) do
    ~H"""
    <div class="rounded-token-lg border border-tymeslot-200 bg-white mb-6">
      <h2 class="display-md p-4 border-b border-tymeslot-200">Recent payments</h2>
      <%= if @payments == [] do %>
        <p class="p-4 text-tymeslot-500">No payments yet.</p>
      <% else %>
        <table class="w-full">
          <thead class="text-left text-token-sm text-tymeslot-500">
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
            <tr :for={p <- @payments} class="border-t border-tymeslot-200">
              <td class="p-2 text-token-sm">{Calendar.strftime(p.inserted_at, "%-d %b %Y")}</td>
              <td class="p-2 text-token-sm">{p.attendee_email}</td>
              <td class="p-2 text-token-sm">{p.meeting_type_name}</td>
              <td class="p-2 text-token-sm text-right">
                {format_amount(p.amount_cents, p.currency)}
              </td>
              <td class="p-2 text-token-sm">{format_status(p.status)}</td>
              <td class="p-2 text-right"></td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp lifetime_stats(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Total received</h3>
        <p class="text-token-2xl font-semibold">{format_amount(@stats.received, "eur")}</p>
      </div>
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Refunded</h3>
        <p class="text-token-2xl font-semibold">{format_amount(@stats.refunded, "eur")}</p>
      </div>
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Platform fee paid</h3>
        <p class="text-token-2xl font-semibold">{format_amount(@stats.platform_fee, "eur")}</p>
      </div>
    </div>
    """
  end

  defp disconnect_zone(assigns) do
    ~H"""
    <details class="rounded-token-lg border border-tymeslot-200 bg-white">
      <summary class="p-4 cursor-pointer text-red-600">Disconnect Stripe</summary>
      <div class="p-4 border-t border-tymeslot-200">
        <p class="text-token-sm text-tymeslot-700 mb-3">
          Disconnect your Stripe account from Tymeslot. Existing payments
          remain visible. New paid bookings will fail until you reconnect.
        </p>
        <button
          type="button"
          class="btn-danger"
          phx-click="disconnect"
          data-confirm="Disconnect Stripe?"
        >
          Disconnect Stripe
        </button>
      </div>
    </details>
    """
  end

  # Status state machine -----------------------------------------------

  defp status_state(%{deleted_at: dt}) when is_struct(dt, DateTime), do: :deleted
  defp status_state(%{disabled_reason: reason}) when is_binary(reason), do: :red
  defp status_state(%{charges_enabled: true, payouts_enabled: true}), do: :green
  defp status_state(%{details_submitted: true}), do: :amber
  defp status_state(_account), do: :amber

  defp state_classes(:green), do: "bg-green-50 border-green-300"
  defp state_classes(:amber), do: "bg-amber-50 border-amber-300"
  defp state_classes(:red), do: "bg-red-50 border-red-300"
  defp state_classes(_state), do: "bg-tymeslot-50 border-tymeslot-200"

  defp state_title(:green), do: "Connected and ready"
  defp state_title(:amber), do: "Pending Stripe review"
  defp state_title(:red), do: "Restricted"
  defp state_title(_state), do: "Not connected"

  defp state_message(%{disabled_reason: r}, :red), do: "Reason: #{r}"

  defp state_message(%{details_submitted: false}, _state),
    do: "You haven't completed Stripe onboarding yet."

  defp state_message(_account, :green), do: "Charges and payouts are enabled."
  defp state_message(_account, :amber), do: "Stripe is reviewing your account."
  defp state_message(_account, _state), do: ""

  # Formatters ---------------------------------------------------------

  defp format_amount(cents, currency) when is_integer(cents) do
    amount = cents / 100
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(amount, decimals: 2)}"
  end

  defp format_amount(_cents, _currency), do: ""

  defp currency_symbol("eur"), do: "€"
  defp currency_symbol("usd"), do: "$"
  defp currency_symbol("gbp"), do: "£"
  defp currency_symbol("chf"), do: "CHF "
  defp currency_symbol(other) when is_binary(other), do: String.upcase(other) <> " "
  defp currency_symbol(_currency), do: ""

  defp format_status("paid"), do: "Paid"
  defp format_status("partially_refunded"), do: "Partially refunded"
  defp format_status("refunded"), do: "Refunded"
  defp format_status("disputed"), do: "Disputed"
  defp format_status("pending"), do: "Pending"
  defp format_status("failed"), do: "Failed"
  defp format_status(other), do: other

  # Used by the refund button rendering once the modal lands; kept here
  # so the helper is colocated with the rest of the row presentation.
  @doc false
  @spec can_refund?(map()) :: boolean()
  def can_refund?(%{status: status, paid_at: paid_at})
      when status in ["paid", "partially_refunded"] do
    not is_nil(paid_at) and
      DateTime.diff(DateTime.utc_now(), paid_at, :day) <= @refund_window_days
  end

  def can_refund?(_payment), do: false
end
