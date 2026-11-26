defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.SeatCancelled do
  @moduledoc """
  Return page after a held group seat's Stripe Checkout is cancelled, for
  every theme.

  Serves `/themes/:theme_slug/payment-cancelled/seat/:seat_hold_id`. Tells
  the booker the seats are not booked and links back to the meeting type,
  drawn by the theme's cancelled page as the meeting's
  (`PaymentReturnLive.Cancelled`) is. A group type takes no invitation, so
  the way back is always the type's booking page.

  The visitor whose `return_token` (the signed proof Stripe's cancel URL
  carries, `Checkout.returned_from_seat_checkout?/2`) matches the hold is
  its booker: for them the page ends the checkout they left
  (`Checkout.abandon_seat_checkout/1`), so the seats are offered again
  within moments rather than at the hold's timeout. Only Stripe's session
  is expired here; its `checkout.session.expired` webhook releases the
  hold. Anyone else holding only the hold's id sees the page and nothing
  happens.
  """

  use TymeslotWeb, :live_view

  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.MeetingPayments.Checkout
  alias TymeslotWeb.Themes.Shared.PaymentReturn
  alias TymeslotWeb.Themes.Shared.PaymentReturn.Seat

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug, "seat_hold_id" => hold_id} = params, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} ->
        path = PaymentReturn.page_path(slug, "payment-cancelled", ["seat", hold_id])
        return_token = params["return_token"]
        guest? = Checkout.returned_from_seat_checkout?(hold_id, return_token)
        query = if guest?, do: %{"return_token" => return_token}, else: %{}

        socket =
          socket
          |> PaymentReturn.assign_language_switcher(path, query)
          |> assign(guest?: guest?)

        {:ok, socket |> load(hold_id, slug) |> abandon_checkout()}

      {:error, :unknown_theme} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket),
    do: PaymentReturn.handle_language_event(event, params, socket)

  # Best effort: a checkout Stripe would not expire still lapses at its
  # timeout, and `abandon_seat_checkout/1` has logged why.
  @impl Phoenix.LiveView
  def handle_async(:abandon_checkout, _result, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :cancelled)

  defp load(socket, hold_id, slug) do
    if connected?(socket) do
      case Seat.lookup(hold_id, slug) do
        {:ok, hold, meeting, profile} ->
          socket
          |> PaymentReturn.assign_customization(profile)
          |> PaymentReturn.assign_organizer(profile, Seat.as_booked(meeting, hold))
          |> assign(
            loading: false,
            seat_hold: hold,
            meeting: meeting,
            rebook_path: PaymentReturn.booking_path(profile, meeting),
            invitation_held: false,
            invitation_withheld: false
          )

        {:error, _reason} ->
          redirect(socket, to: ~p"/")
      end
    else
      socket
      |> Seat.assign_dead_render_language(hold_id, slug)
      |> PaymentReturn.no_customization()
      |> PaymentReturn.no_organizer()
      |> assign(
        loading: true,
        seat_hold: nil,
        meeting: nil,
        rebook_path: nil,
        invitation_held: false,
        invitation_withheld: false
      )
    end
  end

  # Only the booker, on the connected mount of a page that found its hold:
  # the Stripe call runs off the mount, and the webhook it brings releases
  # the hold.
  defp abandon_checkout(%{assigns: %{guest?: true, seat_hold: %{id: hold_id}}} = socket) do
    if connected?(socket) do
      start_async(
        socket,
        :abandon_checkout,
        Tasks.with_context(fn -> Checkout.abandon_seat_checkout(hold_id) end)
      )
    else
      socket
    end
  end

  defp abandon_checkout(socket), do: socket
end
