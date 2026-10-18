defmodule TymeslotWeb.Dashboard.Calendar.FreeBusy do
  @moduledoc """
  The preview's Busy/Free toggle: writes an event's `transparency` through
  the panel's edit path (`PanelEdits.write/4`: the edit guard, the series
  scope for a repeating event, the write queue, an undo entry), with a toast
  that says what the new state means for bookings. A booking and a
  booking's calendar copy follow their meeting type, so the toggle is
  refused for them (`EditGuard.free_busy_editable?/2`), whatever the client
  sends, and an event that is moving to another calendar is not written to.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Shows the event `id` as free (`true`) or busy (`false`)."
  @spec set(socket(), String.t(), boolean()) :: socket()
  def set(socket, id, free?) when is_binary(id) and is_boolean(free?) do
    value = if free?, do: "transparent", else: "opaque"

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         :ok <- editable(socket, event),
         :ok <- not_moving(socket, event),
         false <- (Map.get(event, :transparency) || "opaque") == value do
      PanelEdits.write(socket, id, %{transparency: value}, toast: message(free?))
    else
      {:error, message} -> flash(socket, message)
      _unknown_or_unchanged -> socket
    end
  end

  defp editable(socket, event) do
    if EditGuard.free_busy_editable?(socket.assigns.integrations, event),
      do: :ok,
      else:
        {:error,
         dgettext(
           "dashboard_calendar",
           "Busy or free is set in the meeting type for bookings and their calendar copies."
         )}
  end

  defp not_moving(socket, event) do
    if Transfer.moving?(socket, EventPayload.id(event)),
      do: {:error, CalendarEditMessages.moving_message()},
      else: :ok
  end

  defp flash(socket, message) do
    send(self(), {:flash, {:warning, message}})
    socket
  end

  defp message(true),
    do: dgettext("dashboard_calendar", "Shown as free. Guests can book this time.")

  defp message(false),
    do: dgettext("dashboard_calendar", "Shown as busy. Guests can't book this time.")
end
