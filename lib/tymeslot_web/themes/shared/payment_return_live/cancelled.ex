defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.Cancelled do
  @moduledoc """
  Return page after a Stripe Checkout cancel, for every theme.

  Serves `/themes/:theme_slug/payment-cancelled/:meeting_id`. Tells the
  attendee the booking is not confirmed and links back to the booking page.
  The booking stays in `awaiting_payment` until a `checkout.session.expired`
  webhook moves it to `failed`. No session id is required here, since the
  attendee may arrive from any point in the flow, but the slug must still
  match the host's theme. The page carries the organiser's customisation
  (`PaymentReturn.assign_customization/2`), as their booking page does.
  """

  use TymeslotWeb, :live_view

  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug, "meeting_id" => meeting_id}, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} ->
        path = PaymentReturn.page_path(slug, "payment-cancelled", meeting_id)
        socket = PaymentReturn.assign_language_switcher(socket, path, %{})
        {:ok, load(socket, meeting_id, slug)}

      {:error, :unknown_theme} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket),
    do: PaymentReturn.handle_language_event(event, params, socket)

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :cancelled)

  defp load(socket, meeting_id, slug) do
    if connected?(socket) do
      case PaymentReturn.lookup_for_cancel(meeting_id, slug) do
        {:ok, %{meeting: meeting, profile: profile, rebook_path: rebook_path}} ->
          socket
          |> PaymentReturn.assign_customization(profile)
          |> assign(loading: false, meeting: meeting, rebook_path: rebook_path)

        {:error, _reason} ->
          redirect(socket, to: ~p"/")
      end
    else
      socket
      |> PaymentReturn.no_customization()
      |> assign(loading: true, meeting: nil, rebook_path: nil)
    end
  end
end
