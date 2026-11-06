defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.Cancelled do
  @moduledoc """
  Return page after a Stripe Checkout cancel, for every theme.

  Serves `/themes/:theme_slug/payment-cancelled/:meeting_id`. Tells the
  attendee the booking is not confirmed and links back to the booking page.
  The booking stays in `awaiting_payment` until a `checkout.session.expired`
  webhook moves it to `expired`. A booking made through an invitation holds
  the invitation until then, so the page offers no way back yet and says
  why (`PaymentReturn.rebook/2`); it listens on the meeting's payment topic
  and offers the link, with the invitation's token, once the hold ends. No
  session id is required here, since the attendee may arrive from any point
  in the flow, but the slug must still match the host's theme. The page carries the organiser's customisation
  (`PaymentReturn.assign_customization/2`), as their booking page does, and
  their profile and legal links (`PaymentReturn.assign_organizer/2`).
  """

  use TymeslotWeb, :live_view

  alias Phoenix.PubSub
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"theme_slug" => slug, "meeting_id" => meeting_id}, _session, socket) do
    case PaymentReturn.assign_theme(socket, slug) do
      {:ok, socket} ->
        path = PaymentReturn.page_path(slug, "payment-cancelled", meeting_id)

        socket =
          socket
          |> PaymentReturn.assign_language_switcher(path, %{})
          |> assign(meeting_id: meeting_id, theme_slug: slug)

        # Subscribed before the read, so an `:expired` landing between the
        # two is not missed.
        if connected?(socket),
          do: PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(meeting_id))

        {:ok, load(socket, meeting_id, slug)}

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

  @impl Phoenix.LiveView
  def render(assigns), do: assigns.theme_module.render_payment_page(assigns, :cancelled)

  defp load(socket, meeting_id, slug) do
    if connected?(socket) do
      case PaymentReturn.lookup_for_cancel(meeting_id, slug) do
        {:ok, %{meeting: meeting, profile: profile} = found} ->
          socket
          |> PaymentReturn.assign_customization(profile)
          |> PaymentReturn.assign_organizer(profile)
          |> assign(Map.take(found, [:rebook_path, :invitation_held]))
          |> assign(loading: false, meeting: meeting)

        {:error, _reason} ->
          redirect(socket, to: ~p"/")
      end
    else
      socket
      |> PaymentReturn.no_customization()
      |> PaymentReturn.no_organizer()
      |> assign(loading: true, meeting: nil, rebook_path: nil, invitation_held: false)
    end
  end
end
