defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.Cancelled do
  @moduledoc """
  Return page after a Stripe Checkout cancel, for every theme.

  Serves `/themes/:theme_slug/payment-cancelled/:meeting_id`. Tells the
  attendee the booking is not confirmed and links back to the booking page.
  The booking stays in `awaiting_payment` until a `checkout.session.expired`
  webhook moves it to `expired`. A booking made through an invitation holds
  the invitation until then, so the page offers no way back yet and says
  why (`PaymentReturn.rebook/3`); it listens on the meeting's payment topic
  and offers the link, with the invitation's token, once the hold ends. No
  session id is required here, since the attendee may arrive from any point
  in the flow, but the slug must still match the host's theme.

  The invitation's token is offered only to the guest: a visitor whose
  `return_token` (the signed proof Stripe's cancel URL carries,
  `MeetingPayments.returned_from_checkout?/2`) matches the meeting. For that
  visitor the page also ends the checkout they left
  (`MeetingPayments.abandon_checkout/1`), so the booking's hold, and the
  invitation's, ends within moments rather than at the checkout's timeout.
  Anyone else holding only the meeting id sees the page without the token.
  The page carries the organiser's customisation
  (`PaymentReturn.assign_customization/2`), as their booking page does, and
  their profile and legal links (`PaymentReturn.assign_organizer/3`).
  """

  use TymeslotWeb, :live_view

  alias Phoenix.PubSub
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug, "meeting_id" => meeting_id} = params, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} ->
        path = PaymentReturn.page_path(slug, "payment-cancelled", meeting_id)
        return_token = params["return_token"]
        guest? = MeetingPayments.returned_from_checkout?(meeting_id, return_token)
        query = if guest?, do: %{"return_token" => return_token}, else: %{}

        socket =
          socket
          |> PaymentReturn.assign_language_switcher(path, query)
          |> assign(meeting_id: meeting_id, theme_slug: slug, guest?: guest?)

        # Subscribed before the read, so an `:expired` landing between the
        # two is not missed.
        if connected?(socket),
          do: PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(meeting_id))

        {:ok, socket |> load(meeting_id, slug) |> abandon_checkout()}

      {:error, :unknown_theme} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket),
    do: PaymentReturn.handle_language_event(event, params, socket)

  # The hold ended (or the checkout was paid after all): ask again where the
  # attendee can go back to.
  @impl Phoenix.LiveView
  def handle_info(message, socket) when message in [:paid, :expired],
    do: {:noreply, load(socket, socket.assigns.meeting_id, socket.assigns.theme_slug)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Best effort: a checkout Stripe would not expire still lapses at its
  # timeout, and `abandon_checkout/1` has logged why.
  @impl Phoenix.LiveView
  def handle_async(:abandon_checkout, _result, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :cancelled)

  defp load(socket, meeting_id, slug) do
    if connected?(socket) do
      case PaymentReturn.lookup_for_cancel(meeting_id, slug, socket.assigns.guest?) do
        {:ok, %{meeting: meeting, profile: profile} = found} ->
          socket
          |> PaymentReturn.assign_customization(profile)
          |> PaymentReturn.assign_organizer(profile, meeting)
          |> assign(Map.take(found, [:rebook_path, :invitation_held, :invitation_withheld]))
          |> assign(loading: false, meeting: meeting)

        {:error, _reason} ->
          redirect(socket, to: ~p"/")
      end
    else
      socket
      |> PaymentReturn.assign_dead_render_language(meeting_id, slug)
      |> PaymentReturn.no_customization()
      |> PaymentReturn.no_organizer()
      |> assign(
        loading: true,
        meeting: nil,
        rebook_path: nil,
        invitation_held: false,
        invitation_withheld: false
      )
    end
  end

  # Only the guest, on the connected mount of a page that found its meeting:
  # the Stripe call runs off the mount, and its outcome reaches the page as
  # the payment topic's `:expired`.
  defp abandon_checkout(%{assigns: %{guest?: true, meeting: %{id: meeting_id}}} = socket) do
    if connected?(socket) do
      start_async(
        socket,
        :abandon_checkout,
        Tasks.with_context(fn -> MeetingPayments.abandon_checkout(meeting_id) end)
      )
    else
      socket
    end
  end

  defp abandon_checkout(socket), do: socket
end
