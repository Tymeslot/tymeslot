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

  defp status_card(assigns), do: ~H""

  defp payments_table(assigns), do: ~H""

  defp lifetime_stats(assigns), do: ~H""

  defp disconnect_zone(assigns), do: ~H""
end
