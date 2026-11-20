defmodule TymeslotWeb.Dashboard.Calendar.FreeBusy do
  @moduledoc """
  The preview's Busy/Free toggle: writes an event's `transparency` through
  the panel's edit path (`PanelEdits.write/4`: the edit guard, the series
  scope for a repeating event, the write queue, an undo entry), with a toast
  that says what the new state means for bookings. A booking and a
  booking's calendar copy follow their meeting type, so the toggle is
  refused for them (`EditGuard.free_busy_editable?/2`), whatever the client
  sends. A refusal from the write path (moving, rate limit, seat lock) is flashed,
  since no panel is open to show it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.EditGuard
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Shows the event `id` as free (`true`) or busy (`false`)."
  @spec set(socket(), String.t(), boolean()) :: socket()
  def set(socket, id, free?) when is_binary(id) and is_boolean(free?) do
    value = if free?, do: "transparent", else: "opaque"

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         :ok <- editable(socket, event),
         false <- (Map.get(event, :transparency) || "opaque") == value do
      PanelEdits.write(socket, id, %{transparency: value}, toast: message(socket, event, value))
    else
      {:error, message} -> flash(socket, message)
      _unknown_or_unchanged -> socket
    end
  end

  # A previewed occurrence of a series not yet synced has no free/busy of its
  # own to change: the series' is changed from the series.
  defp editable(_socket, %{preview_of: %{}}),
    do: {:error, elem(CalendarEditMessages.refusal({:error, :syncing}), 1)}

  defp editable(socket, event) do
    if EditGuard.free_busy_editable?(socket.assigns.integrations, event),
      do: :ok,
      else:
        {:error,
         dgettext(
           "dashboard_calendar_editing",
           "Busy or free is set in the meeting type for bookings and their calendar copies."
         )}
  end

  defp flash(socket, message) do
    send(self(), {:flash, {:warning, message}})
    socket
  end

  # What the change means for bookings, said only when the calendar will
  # really read it that way: the same state the preview will then show.
  defp message(socket, event, value) do
    after_change =
      Preview.build(Map.put(event, :transparency, value), Preview.context(socket.assigns))

    case {value, after_change.availability.kind} do
      {"transparent", :free} ->
        dgettext("dashboard_calendar_editing", "Shown as free. Guests can book this time.")

      {"opaque", :busy} ->
        dgettext("dashboard_calendar_editing", "Shown as busy. Guests can't book this time.")

      {"transparent", _other} ->
        dgettext("dashboard_calendar_editing", "Shown as free.")

      {"opaque", _other} ->
        dgettext("dashboard_calendar_editing", "Shown as busy.")
    end
  end
end
