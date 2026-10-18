defmodule TymeslotWeb.Dashboard.Calendar.SurfaceBookingEvents do
  @moduledoc """
  The new calendar's booking and bookable-layer events, routed here by
  `CalendarSurface` so the component stays a router: the preview's booking
  actions (`booking:*`), the rail's Layers section and B, and the work these
  start off the process (`start_async/3`). Each clause hands off to the
  module that owns the behaviour.

  `CalendarSurface` routes every `booking:*` event here, and the `calendar:*`
  events named in its `@booking_events`; a clause added here needs its event
  name added there.
  """

  alias TymeslotWeb.Dashboard.BookingsManagement.RequestActions
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.BookingActions
  alias TymeslotWeb.Dashboard.Calendar.LayerChoices

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Answers an event as `CalendarSurface.handle_event/3` would."
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("booking:" <> name, params, socket),
    do: {:noreply, BookingActions.handle(name, params, socket)}

  # The rail's Layers section and B (see `LayerChoices`).
  def handle("calendar:bookable_toggle", _params, socket),
    do: {:noreply, LayerChoices.toggle(socket)}

  def handle("calendar:bookable_type", %{"id" => id}, socket),
    do: {:noreply, LayerChoices.choose_type(socket, id)}

  def handle("calendar:bookable_type", _params, socket), do: {:noreply, socket}

  @doc "Answers work started off the process, as `CalendarSurface.handle_async/3` would."
  @spec async(term(), {:ok, term()} | {:exit, term()}, socket()) :: {:noreply, socket()}
  def async({:answer_request, _meeting_id} = key, result, socket),
    do: RequestActions.handle_answer(socket, key, result)

  def async(:bookable, result, socket),
    do: {:noreply, BookableLayer.loaded(socket, result)}
end
