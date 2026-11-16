defmodule TymeslotWeb.Dashboard.Calendar.SurfaceBookingEvents do
  @moduledoc """
  The calendar's booking and bookable-layer events, routed here by
  `CalendarSurface` so the component stays a router: the preview's booking
  actions (`booking:*`), the rail's Layers section and B, and the work these
  start off the process (`start_async/3`). Each clause hands off to the
  module that owns the behaviour.

  `CalendarSurface` routes every `booking:*` event here, and the `calendar:*`
  events named in its `@booking_events`; a clause added here needs its event
  name added there.
  """

  alias TymeslotWeb.Dashboard.BookingsManagement.RequestActions
  alias TymeslotWeb.Dashboard.Calendar.BlockTime
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.BookingActions
  alias TymeslotWeb.Dashboard.Calendar.LayerChoices
  alias TymeslotWeb.Dashboard.Calendar.OpenBooking
  alias TymeslotWeb.Dashboard.Calendar.TreatAs

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Answers an event as `CalendarSurface.handle_event/3` would."
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()} | {:reply, map(), socket()}
  def handle("booking:" <> name, params, socket),
    do: {:noreply, BookingActions.handle(name, params, socket)}

  # The rail's Layers section and B (see `LayerChoices`).
  # The hook sends `on` as a boolean, the switch as `phx-value-on`. A hook
  # that has no layer yet (its first load is still running) sends neither,
  # and the saved state flips.
  def handle("calendar:bookable_toggle", params, socket),
    do: {:noreply, LayerChoices.toggle(socket, switched_to(params["on"]))}

  def handle("calendar:bookable_type", %{"id" => id}, socket),
    do: {:noreply, LayerChoices.choose_type(socket, id)}

  def handle("calendar:bookable_type", _params, socket), do: {:noreply, socket}

  # "Block this time" from the bookable layer's explainer (see `BlockTime`).
  # The reply only says whether the block was started.
  def handle("calendar:block", params, socket) do
    {reply, socket} = BlockTime.start(socket, params)
    {:reply, reply, socket}
  end

  # Quick create's "Open for booking": the reply says whether it opened, or
  # which field was refused and why (see `OpenBooking`).
  def handle("calendar:open_booking", params, socket) do
    {reply, socket} = OpenBooking.open(socket, params)
    {:reply, reply, socket}
  end

  # The preview's "Treat as" for an all-day event (see `TreatAs`);
  # anything else it could not have sent is ignored.
  def handle("calendar:bookability", %{"id" => id, "busy" => busy}, socket)
      when is_binary(id) and busy in ["true", "false", "default"],
      do: {:noreply, TreatAs.set(socket, id, busy)}

  def handle("calendar:bookability", _params, socket), do: {:noreply, socket}

  @doc "Answers work started off the process, as `CalendarSurface.handle_async/3` would."
  @spec async(term(), {:ok, term()} | {:exit, term()}, socket()) :: {:noreply, socket()}
  def async({:answer_request, _meeting_id} = key, result, socket),
    do: RequestActions.handle_answer(socket, key, result)

  def async(:bookable, result, socket),
    do: {:noreply, BookableLayer.loaded(socket, result)}

  # A block from the layer's explainer, and that block's undo.
  def async({:block, _n} = key, result, socket),
    do: {:noreply, BlockTime.blocked(socket, key, result)}

  def async({:unblock, _n}, result, socket),
    do: {:noreply, BlockTime.unblocked(socket, result)}

  defp switched_to(on) when is_boolean(on), do: on
  defp switched_to("true"), do: true
  defp switched_to("false"), do: false
  defp switched_to(nil), do: :flip
  defp switched_to(other), do: other
end
