defmodule TymeslotWeb.Dashboard.PaymentsLive do
  @moduledoc """
  Host-facing payments dashboard.

  Surfaces the Stripe Connect onboarding state, recent payments,
  lifetime totals, and the disconnect flow. The whole page is gated
  behind the `:meeting_payments` feature flag.
  """

  use TymeslotWeb, :live_view

  alias Tymeslot.Features
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.PaymentHelpers

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Features.check_access(user.id, :meeting_payments) do
      access when access == :ok or access == {:error, :stripe_required} ->
        {:ok,
         socket
         |> assign(:page_title, "Payments")
         |> assign(:refund_modal_payment, nil)
         |> assign(:refund_submitting, false)
         |> assign(:connect_account, nil)
         |> assign(:payments, [])
         |> assign(:stats, %{received: 0, refunded: 0, platform_fee: 0})
         |> assign(:pending_payments_count, 0)}

      {:error, plan_error} when plan_error in [:insufficient_plan, :pro_required] ->
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
  def handle_params(params, _uri, socket) do
    socket =
      if connected?(socket) do
        user = socket.assigns.current_user
        socket = assign_payments_state(socket, user)

        if Map.has_key?(params, "return") or Map.has_key?(params, "refresh") do
          maybe_enqueue_resync(socket)
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <h1 class="display-md mb-6">Payments</h1>

      <div :if={is_nil(@connect_account)}>
        <.connect_cta />
      </div>
      <div :if={not is_nil(@connect_account)}>
        <.status_card account={@connect_account} />
        <.currency_selector account={@connect_account} />
        <.payments_table payments={@payments} account={@connect_account} />
        <.lifetime_stats stats={@stats} account={@connect_account} />
        <.disconnect_zone pending_count={@pending_payments_count} />
      </div>

      <.refund_modal
        payment={@refund_modal_payment}
        submitting={@refund_submitting}
      />
    </div>
    """
  end

  defp assign_payments_state(socket, user) do
    account = MeetingPayments.get_connect_account_for_user(user.id)
    payments = MeetingPayments.list_payments_for_host(user.id)
    stats = MeetingPayments.lifetime_stats_for_host(user.id)
    pending_count = MeetingPayments.count_pending_payments_for_host(user.id)

    socket
    |> assign(:connect_account, account)
    |> assign(:payments, payments)
    |> assign(:stats, stats)
    |> assign(:pending_payments_count, pending_count)
  end

  # Enqueue a Stripe resync when the host returns from the Express
  # onboarding flow so the dashboard shows fresh capability flags
  # without waiting on the next `account.updated` webhook. Worker
  # uniqueness keeps repeated returns within a 60-second window from
  # piling up duplicate jobs.
  defp maybe_enqueue_resync(socket) do
    case socket.assigns[:connect_account] do
      %{stripe_account_id: stripe_account_id} when is_binary(stripe_account_id) ->
        MeetingPayments.enqueue_resync_for_account(stripe_account_id)
        socket

      _missing ->
        socket
    end
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

    case MeetingPayments.disconnect(user) do
      {:ok, %{cancelled_count: 0}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stripe account disconnected.")
         |> assign_payments_state(user)}

      {:ok, %{cancelled_count: n}} ->
        noun = if n == 1, do: "booking", else: "bookings"

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Stripe account disconnected. #{n} pending #{noun} cancelled."
         )
         |> assign_payments_state(user)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not disconnect Stripe. Please try again.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("change_currency", %{"currency" => currency}, socket) do
    user = socket.assigns.current_user

    cond do
      is_nil(socket.assigns.connect_account) ->
        {:noreply, socket}

      not MeetingPayments.currency_allowed?(currency) ->
        {:noreply, put_flash(socket, :error, "Currency not supported.")}

      currency == socket.assigns.connect_account.default_currency ->
        {:noreply, socket}

      true ->
        case MeetingPayments.change_default_currency(socket.assigns.connect_account, currency) do
          {:ok, :reset} ->
            {:noreply,
             socket
             |> put_flash(:info, "Currency updated. Paid event-type prices have been reset.")
             |> assign_payments_state(user)}

          {:ok, :no_reset} ->
            {:noreply,
             socket
             |> put_flash(:info, "Currency updated.")
             |> assign_payments_state(user)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not update currency. Please try again.")}
        end
    end
  end

  @impl Phoenix.LiveView
  def handle_event("open_refund_modal", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    payment = MeetingPayments.get_payment(id)

    cond do
      is_nil(payment) ->
        {:noreply, socket}

      payment.host_user_id != user.id ->
        {:noreply, socket}

      not MeetingPayments.refundable?(payment) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This payment can no longer be refunded from Tymeslot. " <>
             "Refunds older than 60 days must be processed in your Stripe dashboard."
         )}

      true ->
        {:noreply, assign(socket, :refund_modal_payment, payment)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("close_refund_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:refund_modal_payment, nil)
     |> assign(:refund_submitting, false)}
  end

  @impl Phoenix.LiveView
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
        # Refunds.issue_refund/3 call still acquires a FOR UPDATE lock, so
        # this is defence-in-depth rather than a guarantee.
        case MeetingPayments.get_payment(payment.id) do
          nil -> {:noreply, socket}
          fresh_payment -> do_submit_refund(socket, fresh_payment, params)
        end
    end
  end

  defp do_submit_refund(socket, payment, params) do
    case MeetingPayments.parse_refund_amount(payment, params) do
      {:ok, amount_cents} ->
        socket = assign(socket, :refund_submitting, true)
        process_refund(socket, payment, amount_cents)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, parse_refund_error_message(reason))}
    end
  end

  defp parse_refund_error_message(:choose_type), do: "Choose a refund type."
  defp parse_refund_error_message(:invalid_amount), do: "Enter a valid refund amount."
  defp parse_refund_error_message(:exceeds_remaining), do: "Amount exceeds the remaining refundable balance."

  defp process_refund(socket, payment, amount_cents) do
    user = socket.assigns.current_user

    case MeetingPayments.issue_refund(payment, amount_cents) do
      {:ok, _payment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Refund issued. The attendee will receive a confirmation email.")
         |> assign(:refund_modal_payment, nil)
         |> assign(:refund_submitting, false)
         |> assign_payments_state(user)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, refund_error_message(reason))
         |> assign(:refund_submitting, false)}
    end
  end

  defp refund_error_message(:outside_refund_window),
    do: "Refunds older than 60 days must be processed in your Stripe dashboard."

  defp refund_error_message(:already_refunded),
    do: "This payment has already been fully refunded."

  defp refund_error_message(:invalid_amount),
    do: "Refund amount must be greater than zero and within the remaining balance."

  defp refund_error_message(:not_paid),
    do: "This booking has not been paid yet, so it cannot be refunded."

  defp refund_error_message(:missing_charge),
    do: "Stripe has not yet captured a charge for this booking. Try again in a moment."

  defp refund_error_message(_other),
    do: "Something went wrong while issuing the refund. Please try again."

  defp currency_selector(assigns) do
    assigns = assign(assigns, :currencies, MeetingPayments.currency_allowlist())

    ~H"""
    <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4 mb-6">
      <h3 class="text-token-sm text-tymeslot-500 mb-2">Default currency</h3>
      <p class="text-token-sm text-tymeslot-700 mb-3">
        Changing the currency will reset every paid event type to free —
        existing prices are recorded in the previous currency and would
        otherwise be charged at the new one.
      </p>
      <form phx-change="change_currency">
        <CoreComponents.input
          type="select"
          name="currency"
          label="Default currency"
          options={Enum.map(@currencies, fn code -> {String.upcase(code), code} end)}
          value={@account.default_currency}
        />
      </form>
    </div>
    """
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
      <p :if={@payments == []} class="p-4 text-tymeslot-500">No payments yet.</p>
      <table :if={@payments != []} class="w-full">
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
            <td class="p-2 text-right">
              <button
                :if={MeetingPayments.refundable?(p) and not connect_account_deleted?(@account)}
                type="button"
                class="text-token-sm text-tymeslot-700 underline"
                phx-click="open_refund_modal"
                phx-value-id={p.id}
              >
                Refund
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp refund_modal(assigns) do
    ~H"""
    <CoreComponents.modal
      :if={@payment}
      id="refund-modal"
      show={true}
      on_cancel={Phoenix.LiveView.JS.push("close_refund_modal")}
      size={:medium}
    >
      <:header>
        <span class="display-md">Refund payment</span>
      </:header>

      <div class="space-y-4">
        <p class="text-tymeslot-700">
          Refund <strong>{@payment.attendee_name || @payment.attendee_email}</strong>
          for <strong>{@payment.meeting_type_name}</strong>.
        </p>

        <div class="rounded-token-md border border-tymeslot-200 bg-tymeslot-50 p-3 text-token-sm">
          <p>
            Original charge: <strong>{format_amount(@payment.amount_cents, @payment.currency)}</strong>
          </p>
          <p>
            Already refunded:
            <strong>{format_amount(@payment.refunded_amount_cents, @payment.currency)}</strong>
          </p>
          <p>
            Remaining refundable:
            <strong>{format_amount(MeetingPayments.refundable_remaining_cents(@payment), @payment.currency)}</strong>
          </p>
        </div>

        <p class="text-token-sm text-tymeslot-700">
          The attendee receives the full amount you refund. Tymeslot's platform fee is
          reversed proportionally; Stripe processing fees on the original charge stay
          with you.
        </p>

        <form id="refund-form" phx-submit="submit_refund" class="space-y-4">
          <input type="hidden" name="payment_id" value={@payment.id} />

          <fieldset class="space-y-2">
            <legend class="text-token-sm font-semibold text-tymeslot-700">Refund type</legend>
            <label class="flex items-center gap-2 text-token-sm">
              <input
                type="radio"
                name="refund_type"
                value="full"
                checked
                phx-click={Phoenix.LiveView.JS.set_attribute({"data-refund-type", "full"}, to: "#refund-form")}
              /> Full refund ({format_amount(MeetingPayments.refundable_remaining_cents(@payment), @payment.currency)})
            </label>
            <label class="flex items-center gap-2 text-token-sm">
              <input
                type="radio"
                name="refund_type"
                value="partial"
                phx-click={Phoenix.LiveView.JS.set_attribute({"data-refund-type", "partial"}, to: "#refund-form")}
              /> Partial refund
            </label>
          </fieldset>

          <CoreComponents.input
            type="number"
            name="amount"
            label="Partial amount"
            min="0.01"
            max={MeetingPayments.refundable_remaining_cents(@payment) / 100}
            step="0.01"
            placeholder={"0.00 #{String.upcase(@payment.currency || "")}"}
          />
        </form>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button
            variant={:secondary}
            phx-click="close_refund_modal"
          >
            Cancel
          </CoreComponents.action_button>
          <CoreComponents.loading_button
            type="submit"
            form="refund-form"
            variant={:danger}
            loading={@submitting}
            loading_text="Refunding..."
          >
            Issue refund
          </CoreComponents.loading_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  defp connect_account_deleted?(%{deleted_at: %DateTime{}}), do: true
  defp connect_account_deleted?(_account), do: false

  # `lifetime_stats` is only rendered when `connect_account` is non-nil (see
  # the `:if={not is_nil(@connect_account)}` guard in render/1), so
  # `account.default_currency` is always available here.
  defp lifetime_stats(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Total received</h3>
        <p class="text-token-2xl font-semibold">
          {format_amount(@stats.received, @account.default_currency)}
        </p>
      </div>
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Refunded</h3>
        <p class="text-token-2xl font-semibold">
          {format_amount(@stats.refunded, @account.default_currency)}
        </p>
      </div>
      <div class="rounded-token-lg border border-tymeslot-200 bg-white p-4">
        <h3 class="text-token-sm text-tymeslot-500">Platform fee paid</h3>
        <p class="text-token-2xl font-semibold">
          {format_amount(@stats.platform_fee, @account.default_currency)}
        </p>
      </div>
    </div>
    """
  end

  defp disconnect_zone(assigns) do
    assigns =
      assign(
        assigns,
        :confirm_message,
        disconnect_confirm_message(assigns.pending_count)
      )

    ~H"""
    <details class="rounded-token-lg border border-tymeslot-200 bg-white">
      <summary class="p-4 cursor-pointer text-red-600">Disconnect Stripe</summary>
      <div class="p-4 border-t border-tymeslot-200">
        <p class="text-token-sm text-tymeslot-700 mb-3">
          Disconnect your Stripe account from Tymeslot. Existing payments
          remain visible. New paid bookings will fail until you reconnect.
        </p>
        <p :if={@pending_count > 0} class="text-token-sm text-amber-700 mb-3">
          You have {@pending_count} pending {if @pending_count == 1,
            do: "booking",
            else: "bookings"} awaiting payment. Disconnecting will cancel {if @pending_count == 1,
            do: "it",
            else: "them"}.
        </p>
        <button
          type="button"
          class="btn-danger"
          phx-click="disconnect"
          data-confirm={@confirm_message}
        >
          Disconnect Stripe
        </button>
      </div>
    </details>
    """
  end

  defp disconnect_confirm_message(0), do: "Disconnect Stripe?"

  defp disconnect_confirm_message(n) do
    noun = if n == 1, do: "booking", else: "bookings"
    "Disconnect Stripe? This will cancel #{n} pending #{noun}."
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

  defp format_amount(cents, currency), do: PaymentHelpers.format_amount(cents, currency)

  defp format_status("paid"), do: "Paid"
  defp format_status("partially_refunded"), do: "Partially refunded"
  defp format_status("refunded"), do: "Refunded"
  defp format_status("disputed"), do: "Disputed"
  defp format_status("pending"), do: "Pending"
  defp format_status("failed"), do: "Failed"
  defp format_status(other), do: other

end
