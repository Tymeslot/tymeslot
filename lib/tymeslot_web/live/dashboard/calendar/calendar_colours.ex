defmodule TymeslotWeb.Dashboard.Calendar.CalendarColours do
  @moduledoc """
  Each calendar's own colour, chosen in the rail or the Calendars sheet: a
  calendar's swatch button opens its palette under it
  (`calendar:calendar_colour_open`, the one open at a time in
  `calendar_colour_open`), and a swatch stores the choice
  (`calendar:set_calendar_colour`) through
  `Tymeslot.Integrations.Calendar.Appearance.set_colour/4`, which checks the
  account is the organiser's and charges the appearance budget. "Default
  colour" clears it back to the account's.

  A stored choice repaints at once: the colours are read again
  (`SurfaceData.reload_colours/1`, no events query) and the window pushed
  with a cache reset.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle(
        "calendar:calendar_colour_open",
        %{"integration-id" => raw_id, "calendar-id" => calendar_id},
        socket
      ) do
    wanted = with {:ok, id} <- parse_id(raw_id), do: {id, calendar_id}
    open = if wanted == socket.assigns.calendar_colour_open, do: nil, else: wanted
    {:noreply, assign(socket, :calendar_colour_open, if(open == :error, do: nil, else: open))}
  end

  def handle(
        "calendar:set_calendar_colour",
        %{"integration-id" => raw_id, "calendar-id" => calendar_id, "colour" => colour},
        socket
      ) do
    with {:ok, id} <- parse_id(raw_id),
         {:ok, key} <- parse_colour(colour),
         {:ok, _appearance} <-
           Appearance.set_colour(socket.assigns.current_user.id, id, calendar_id, key) do
      {:noreply, SurfaceData.reload_colours(socket)}
    else
      {:error, {:rate_limited, message}} ->
        {:noreply, Flash.put_flash(socket, :warning, message)}

      _refused ->
        {:noreply,
         Flash.put_flash(
           socket,
           :error,
           dgettext("dashboard_calendar", "Couldn't save that colour. Please try again.")
         )}
    end
  end

  def handle(_event, _params, socket), do: {:noreply, socket}

  defp parse_id(raw) when is_integer(raw), do: {:ok, raw}

  defp parse_id(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> {:ok, id}
      _other -> :error
    end
  end

  defp parse_id(_raw), do: :error

  # "default" is the swatches' clearing sentinel; anything else must be a
  # palette key (the schema checks again).
  defp parse_colour("default"), do: {:ok, nil}

  defp parse_colour(colour) when is_binary(colour) do
    if EventColour.valid_key?(colour), do: {:ok, colour}, else: :error
  end

  defp parse_colour(_colour), do: :error
end
