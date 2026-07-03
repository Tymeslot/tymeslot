defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
  @moduledoc """
  Host-facing payments dashboard, rendered inside the dashboard shell.

  Surfaces the Stripe Connect onboarding state, recent payments, lifetime
  totals, the default-currency selector, the refund flow, and the disconnect
  flow. The whole section is gated behind the `:meeting_payments` feature
  (the gate itself lives in `DashboardLive.handle_params/3`).

  This component owns only orchestration: data loading, event handling, and
  composing the presentational sub-components under
  `TymeslotWeb.Dashboard.PaymentsSettings.*`. Following the dashboard
  convention, it reloads the host's connect account, payments, stats, and
  pending count in `update/2`. Flash messages are forwarded to the parent
  LiveView via `Flash` (a bare `put_flash/3` inside a LiveComponent never
  reaches the rendered flash group).
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.MeetingPayments

  import TymeslotWeb.Dashboard.PaymentsSettings.ConnectCta, only: [connect_cta: 1]
  import TymeslotWeb.Dashboard.PaymentsSettings.CurrencySelector, only: [currency_selector: 1]
  import TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModal, only: [disconnect_modal: 1]
  import TymeslotWeb.Dashboard.PaymentsSettings.LifetimeStats, only: [lifetime_stats: 1]
  import TymeslotWeb.Dashboard.PaymentsSettings.PaymentsTable, only: [payments_table: 1]
  import TymeslotWeb.Dashboard.PaymentsSettings.RefundModal, only: [refund_modal: 1]

  import TymeslotWeb.Dashboard.PaymentsSettings.StatusCard,
    only: [status_card: 1, needs_onboarding?: 1]

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     socket
     |> assign(:refund_modal_payment, nil)
     |> assign(:refund_submitting, false)
     |> assign(:disconnect_modal_open, false)
     |> assign(:connect_account, nil)
     |> assign(:payments, [])
     |> assign(:stats, %{received: 0, refunded: 0, platform_fee: 0})
     |> assign(:pending_payments_count, 0)}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign_payments_state(socket, socket.assigns.current_user)}
  end

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="payments-settings" class="space-y-10 pb-20">
      <.section_header icon="hero-credit-card" title="Payments" />

      <div :if={is_nil(@connect_account)}>
        <.connect_cta />
      </div>

      <div :if={not is_nil(@connect_account)} class="space-y-8">
        <.status_card account={@connect_account} />

        <%!--
          The operational sections (currency, payments, stats, disconnect) only
          make sense once onboarding is submitted. While the account is still
          `:incomplete`, the StatusCard shows the Continue-onboarding prompt and
          we render nothing else, so the host is never stuck on a dead-end card.
        --%>
        <div :if={not needs_onboarding?(@connect_account)} class="space-y-8">
          <.currency_selector account={@connect_account} myself={@myself} />
          <.payments_table payments={@payments} account={@connect_account} myself={@myself} />
          <.lifetime_stats stats={@stats} account={@connect_account} />
          <.disconnect_zone myself={@myself} />
        </div>
      </div>

      <.refund_modal
        payment={@refund_modal_payment}
        submitting={@refund_submitting}
        myself={@myself}
      />

      <.disconnect_modal
        open={@disconnect_modal_open}
        pending_count={@pending_payments_count}
        myself={@myself}
      />
    </div>
    """
  end

  defp disconnect_zone(assigns) do
    ~H"""
    <.detail_card title="Disconnect Stripe">
      <p class="text-token-sm text-tymeslot-700 mb-3">
        Disconnect your Stripe account from Tymeslot. Existing payments
        remain visible. New paid bookings will fail until you reconnect.
      </p>
      <.action_button
        variant={:danger}
        phx-click="open_disconnect_modal"
        phx-target={@myself}
      >
        Disconnect Stripe
      </.action_button>
    </.detail_card>
    """
  end

  # ── Event handlers ────────────────────────────────────────────────

  @impl Phoenix.LiveComponent
  def handle_event("open_disconnect_modal", _params, socket) do
    {:noreply, assign(socket, :disconnect_modal_open, true)}
  end

  def handle_event("close_disconnect_modal", _params, socket) do
    {:noreply, assign(socket, :disconnect_modal_open, false)}
  end

  def handle_event("disconnect", _params, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :disconnect_modal_open, false)

    case MeetingPayments.disconnect(user) do
      {:ok, %{cancelled_count: 0}} ->
        Flash.info("Stripe account disconnected.")
        {:noreply, assign_payments_state(socket, user)}

      {:ok, %{cancelled_count: n}} ->
        noun = if n == 1, do: "booking", else: "bookings"
        Flash.info("Stripe account disconnected. #{n} pending #{noun} cancelled.")
        {:noreply, assign_payments_state(socket, user)}

      {:error, _reason} ->
        Flash.error("Could not disconnect Stripe. Please try again.")
        {:noreply, socket}
    end
  end

  def handle_event("change_currency", %{"currency" => currency}, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(socket.assigns.connect_account) ->
        {:noreply, socket}

      not MeetingPayments.currency_allowed?(currency) ->
        Flash.error("Currency not supported.")
        {:noreply, socket}

      currency == socket.assigns.connect_account.default_currency ->
        {:noreply, socket}

      true ->
        change_currency(socket, user, currency)
    end
  end

  def handle_event("open_refund_modal", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    payment = MeetingPayments.get_payment(id)

    cond do
      is_nil(payment) ->
        {:noreply, socket}

      payment.host_user_id != user.id ->
        {:noreply, socket}

      not MeetingPayments.refundable?(payment) ->
        Flash.error(
          "This payment can no longer be refunded from Tymeslot. " <>
            "Refunds older than 60 days must be processed in your Stripe dashboard."
        )

        {:noreply, socket}

      true ->
        {:noreply, assign(socket, :refund_modal_payment, payment)}
    end
  end

  def handle_event("close_refund_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:refund_modal_payment, nil)
     |> assign(:refund_submitting, false)}
  end

  def handle_event("submit_refund", params, socket) do
    user = socket.assigns.current_user
    payment = socket.assigns.refund_modal_payment

    cond do
      is_nil(payment) ->
        {:noreply, socket}

      payment.host_user_id != user.id ->
        {:noreply, socket}

      true ->
        # Re-fetch from DB to pick up any concurrent state changes (e.g. a
        # refund issued from another tab) before parsing the amount. The
        # MeetingPayments.issue_refund/2 call still acquires a FOR UPDATE
        # lock, so this is defence-in-depth rather than a guarantee.
        case MeetingPayments.get_payment(payment.id) do
          nil -> {:noreply, socket}
          fresh_payment -> do_submit_refund(socket, fresh_payment, params)
        end
    end
  end

  # ── Private orchestration ─────────────────────────────────────────

  defp change_currency(socket, user, currency) do
    case MeetingPayments.change_default_currency(socket.assigns.connect_account, currency) do
      {:ok, :reset} ->
        Flash.info("Currency updated. Paid event-type prices have been reset.")
        {:noreply, assign_payments_state(socket, user)}

      {:ok, :no_reset} ->
        Flash.info("Currency updated.")
        {:noreply, assign_payments_state(socket, user)}

      {:error, _reason} ->
        Flash.error("Could not update currency. Please try again.")
        {:noreply, socket}
    end
  end

  defp do_submit_refund(socket, payment, params) do
    case MeetingPayments.parse_refund_amount(payment, params) do
      {:ok, amount_cents} ->
        process_refund(assign(socket, :refund_submitting, true), payment, amount_cents)

      {:error, reason} ->
        Flash.error(parse_refund_error_message(reason))
        {:noreply, socket}
    end
  end

  # Run the blocking Stripe refund call in an async task so the
  # `refund_submitting` spinner actually paints — assigning it and then making
  # the synchronous call in the same handle_event would never yield a render
  # between the two. We re-assert host ownership inside the task closure so a
  # forged/raced request still cannot refund another host's payment, and
  # `issue_refund/2` itself re-locks and re-validates the row under FOR UPDATE.
  defp process_refund(socket, payment, amount_cents) do
    user_id = socket.assigns.current_user.id
    payment_id = payment.id

    {:noreply,
     start_async(socket, :issue_refund, fn ->
       issue_refund_authorized(payment_id, user_id, amount_cents)
     end)}
  end

  defp issue_refund_authorized(payment_id, user_id, amount_cents) do
    case MeetingPayments.get_payment(payment_id) do
      %{host_user_id: ^user_id} = fresh_payment ->
        MeetingPayments.issue_refund(fresh_payment, amount_cents)

      _missing_or_not_owner ->
        {:error, :not_authorized}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_async(:issue_refund, {:ok, {:ok, _payment}}, socket) do
    Flash.info("Refund issued. The attendee will receive a confirmation email.")

    {:noreply,
     socket
     |> assign(:refund_modal_payment, nil)
     |> assign(:refund_submitting, false)
     |> assign_payments_state(socket.assigns.current_user)}
  end

  def handle_async(:issue_refund, {:ok, {:error, reason}}, socket) do
    handle_refund_failure(socket, reason)
  end

  def handle_async(:issue_refund, {:exit, reason}, socket) do
    handle_refund_failure(socket, reason)
  end

  defp handle_refund_failure(socket, reason) do
    Flash.error(refund_error_message(reason))
    {:noreply, assign(socket, :refund_submitting, false)}
  end

  defp assign_payments_state(socket, user) do
    socket
    |> assign(:connect_account, MeetingPayments.get_connect_account_for_user(user.id))
    |> assign(:payments, MeetingPayments.list_payments_for_host(user.id))
    |> assign(:stats, MeetingPayments.lifetime_stats_for_host(user.id))
    |> assign(:pending_payments_count, MeetingPayments.count_pending_payments_for_host(user.id))
  end

  defp parse_refund_error_message(:choose_type), do: "Choose a refund type."
  defp parse_refund_error_message(:invalid_amount), do: "Enter a valid refund amount."

  defp parse_refund_error_message(:exceeds_remaining),
    do: "Amount exceeds the remaining refundable balance."

  defp refund_error_message(:outside_refund_window),
    do: "Refunds older than 60 days must be processed in your Stripe dashboard."

  defp refund_error_message(:already_refunded),
    do: "This payment has already been fully refunded."

  defp refund_error_message(:under_dispute),
    do: "This payment is under dispute and must be handled in your Stripe dashboard."

  defp refund_error_message(:invalid_amount),
    do: "Refund amount must be greater than zero and within the remaining balance."

  defp refund_error_message(:not_paid),
    do: "This booking has not been paid yet, so it cannot be refunded."

  defp refund_error_message(:missing_charge),
    do: "Stripe has not yet captured a charge for this booking. Try again in a moment."

  defp refund_error_message(_other),
    do: "Something went wrong while issuing the refund. Please try again."
end
