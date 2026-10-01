defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.Processing do
  @moduledoc """
  Return page after a successful Stripe Checkout redirect, for every theme.

  Serves `/themes/:theme_slug/payment-processing/:meeting_id`, the success URL
  `Tymeslot.MeetingPayments.CheckoutSessions` gives Stripe. The slug selects
  the theme: `PaymentReturn.assign_theme/2` assigns `:theme_id` (so the root
  layout loads that theme's stylesheet) and `:theme_module`, whose
  `render_payment_page/2` draws the theme's shell around the shared body, in
  the organiser's customisation (`PaymentReturn.assign_customization/2`).

  The attendee lands here while the webhook is still in flight. The page
  subscribes to PubSub and re-reads the meeting on `:paid` or `:expired`
  (`PaymentReturn.refresh/1`); the webhook, not this page, is the source of
  truth, and this page never mutates state. Paid does not always mean
  confirmed: a paid, approval-gated booking moves to `"awaiting_approval"`,
  which `PaymentReturn.outcome/3` reports as such.
  """

  use TymeslotWeb, :live_view

  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug} = params, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} -> PaymentReturn.mount_payment_processing(params, socket, slug)
      {:error, :unknown_theme} -> {:ok, PaymentReturn.reject(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket),
    do: PaymentReturn.handle_language_event(event, params, socket)

  @impl Phoenix.LiveView
  def handle_info(message, socket) when message in [:paid, :expired] do
    {:noreply, PaymentReturn.refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :processing)
end
