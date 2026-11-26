defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.SeatProcessing do
  @moduledoc """
  Return page after a held group seat's Stripe Checkout succeeds, for every
  theme.

  Serves `/themes/:theme_slug/payment-processing/seat/:seat_hold_id`, the
  success URL `Tymeslot.MeetingPayments.CheckoutSessions` gives Stripe for a
  seat hold, drawn by the theme's processing page as the meeting's
  (`PaymentReturnLive.Processing`) is. The booker lands here while the
  webhook is still in flight; the page listens on the hold's topic and
  re-reads the hold on `{:paid, participant_id}` or `:expired`
  (`PaymentReturn.Seat.refresh/1`). Its outcome is the hold's
  (`Checkout.seat_checkout_outcome/2`), never the shared meeting's, and the page
  never changes anything.
  """

  use TymeslotWeb, :live_view

  alias TymeslotWeb.Themes.Shared.PaymentReturn
  alias TymeslotWeb.Themes.Shared.PaymentReturn.Seat

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug} = params, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} -> Seat.mount_processing(params, socket, slug)
      {:error, :unknown_theme} -> {:ok, PaymentReturn.reject(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket),
    do: PaymentReturn.handle_language_event(event, params, socket)

  @impl Phoenix.LiveView
  def handle_info({:paid, _participant_id}, socket), do: {:noreply, Seat.refresh(socket)}
  def handle_info(:expired, socket), do: {:noreply, Seat.refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :processing)
end
