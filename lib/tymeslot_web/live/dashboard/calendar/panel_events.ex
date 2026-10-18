defmodule TymeslotWeb.Dashboard.Calendar.PanelEvents do
  @moduledoc """
  Every event the side panel sends, `panel:<name>`, handled on the
  calendar surface: `CalendarSurface` has one clause for them and passes the
  name here. Each one reads the panel's event from the surface
  (`PanelState.current_event/1`), so an event arriving with no panel open
  changes nothing, and parameters are client input, matched before use.
  """

  alias Tymeslot.CalendarGrid.EditGuard
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelFields
  alias TymeslotWeb.Dashboard.Calendar.PanelState

  # The text fields, by the event each sends (see `PanelFields.text_change/2`).
  @text_fields ~w(title location notes)

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Handles the panel event `name` with its `params`."
  @spec handle(String.t(), map(), socket()) :: socket()
  # Closing while a text field has focus: the hook sends the field and its
  # value, since the field's own blur never reaches the server once the
  # panel is gone. It is saved as that blur would save it, then the panel
  # closes, unless the value was refused or the series question is now on
  # screen, either of which keeps it open.
  def handle("close", %{"field" => field, "value" => value}, socket)
      when field in @text_fields and is_binary(value) do
    socket = socket |> clear_failure() |> then(&handle(field, %{"value" => value}, &1))

    case socket.assigns do
      %{panel: %{errors: %{^field => _message}}} -> socket
      %{series_prompt: %{kind: :panel}} -> socket
      %{panel: %{status: {:failed, _reason}}} -> socket
      _saved_or_unchanged -> PanelState.close(socket)
    end
  end

  def handle("close", _params, socket), do: PanelState.close(socket)

  def handle(field, %{"value" => value}, socket)
      when field in @text_fields and is_binary(value) do
    case {PanelState.current_event(socket.assigns), PanelFields.text_change(field, value)} do
      {nil, _change} -> socket
      {_event, {:ok, changes}} -> socket |> PanelState.put_error(field, nil) |> write(changes)
      {_event, {:error, message}} -> PanelState.put_error(socket, field, message)
    end
  end

  # Free or busy is not the organiser's to change on a booking or a booking's
  # calendar copy (the panel does not draw the switch for them either).
  def handle("free", %{"value" => choice}, socket) when choice in ["busy", "free"] do
    with %{} = event <- PanelState.current_event(socket.assigns),
         true <- EditGuard.movable?(socket.assigns.integrations, event) do
      write(socket, %{transparency: PanelFields.transparency(choice)})
    else
      _no_panel_or_not_changeable -> socket
    end
  end

  def handle("reminder", %{"reminder" => choice}, socket) when is_binary(choice) do
    with %{} = event <- PanelState.current_event(socket.assigns),
         {:ok, reminders} <- PanelFields.reminders(Map.get(event, :reminders) || [], choice) do
      write(socket, %{reminders: reminders})
    else
      _no_panel_or_not_offered -> socket
    end
  end

  def handle(_name, _params, socket), do: socket

  # An older failure must not read as this attempt's refusal.
  defp clear_failure(socket),
    do:
      PanelState.update(
        socket,
        &if(match?({:failed, _}, &1.status), do: %{&1 | status: :idle}, else: &1)
      )

  # Writes to the panel's own event; with no panel open, nothing.
  defp write(socket, changes, opts \\ [])

  defp write(%{assigns: %{panel: %{event_id: id}}} = socket, changes, opts),
    do: PanelEdits.write(socket, id, changes, opts)

  defp write(socket, _changes, _opts), do: socket
end
