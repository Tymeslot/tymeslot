defmodule TymeslotWeb.Dashboard.Calendar.PanelEvents do
  @moduledoc """
  Every event the side panel sends, `panel:<name>`, handled on the
  calendar surface: `CalendarSurface` has one clause for them and passes the
  name here. Each one reads the panel's event from the surface
  (`PanelState.current_event/1`), so an event arriving with no panel open
  changes nothing, and parameters are client input, matched before use.
  """

  alias TymeslotWeb.Dashboard.Calendar.PanelState

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Handles the panel event `name` with its `params`."
  @spec handle(String.t(), map(), socket()) :: socket()
  def handle("close", _params, socket), do: PanelState.close(socket)

  def handle(_name, _params, socket), do: socket
end
