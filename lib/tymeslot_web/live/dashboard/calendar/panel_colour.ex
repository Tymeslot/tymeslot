defmodule TymeslotWeb.Dashboard.Calendar.PanelColour do
  @moduledoc """
  The side panel's Colour row: the shared palette (`ColourSwatches`) for an
  event the organiser can change, and what a swatch does (`panel:colour`).

  A colour is kept as the organiser's override on the event
  (`Calendar.set_event_colour/3`), which the calendar paints with whatever
  its provider holds, and which is written back to the provider where it has
  a per-event colour (Google, CalDAV; Outlook has none). "Default colour"
  clears the override (`Calendar.clear_event_colour/2`), whose write-back
  clears the provider's colour too, replacing a write-back of the old colour
  still waiting. Either way the change is the event's colour alone: no
  series question, no undo entry. It passes the same guard as any other
  change, once (`EditGuard.check/3`), then repaints the grid from the
  overrides read again (`SurfaceData.reload_overrides/1`, no events query).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.Dashboard.ColourSwatches
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  attr :colour, :string, default: nil, doc: "the palette key the event paints with, or nil"
  attr :surface, :any, required: true

  @spec colour_field(map()) :: Phoenix.LiveView.Rendered.t()
  def colour_field(assigns) do
    ~H"""
    <section id="calendar-panel-colour" class="space-y-2">
      <h3 class="label mb-0">{dgettext("dashboard_calendar_editing", "Colour")}</h3>
      <ColourSwatches.colour_swatches
        selected={@colour}
        event="panel:colour"
        target={@surface}
        group_label={dgettext("dashboard_calendar_editing", "Colour")}
      />
    </section>
    """
  end

  @doc "Stores the colour a swatch sent for the panel's event, or clears it (`\"default\"`)."
  @spec set(socket(), term()) :: socket()
  def set(socket, colour) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with %{} = event <- PanelState.current_event(socket.assigns),
         {:ok, target} <- target(event),
         {:ok, key} <- parse(colour),
         :ok <- EditGuard.check(user.id, integrations, event),
         :ok <- write(user.id, target, key) do
      socket |> shown_cleared(event, key) |> SurfaceData.reload_overrides()
    else
      {:error, :rate_limited, _message} = refusal -> refused(socket, refusal)
      {:error, reason} = refusal when reason != :not_found -> refused(socket, refusal)
      :failed -> failed(socket)
      _ignored -> socket
    end
  end

  # Only a calendar event the organiser's integration holds has an override
  # to keep; a booking paints as a booking.
  defp target(%{kind: :booking}), do: :error

  defp target(%{calendar_integration_id: integration_id, uid: uid})
       when is_integer(integration_id) and is_binary(uid),
       do: {:ok, {:external, integration_id, uid}}

  defp target(_event), do: :error

  defp parse("default"), do: {:ok, nil}

  defp parse(colour) when is_binary(colour),
    do: if(EventColour.valid_key?(colour), do: {:ok, colour}, else: :error)

  defp parse(_colour), do: :error

  defp write(user_id, target, nil) do
    case Calendar.clear_event_colour(user_id, target) do
      :ok -> :ok
      _failure -> :failed
    end
  end

  defp write(user_id, target, key) do
    case Calendar.set_event_colour(user_id, target, key) do
      {:ok, _override} -> :ok
      _failure -> :failed
    end
  end

  # A cleared colour is cleared from the cached event as well, where its
  # provider keeps one (`Calendar.clear_event_colour/2`); the loaded copy
  # follows it.
  defp shown_cleared(socket, event, nil) do
    if Calendar.host_event_colour?(Map.get(event, :provider)),
      do: SurfaceData.show_event(socket, Map.put(event, :colour, nil)),
      else: socket
  end

  defp shown_cleared(socket, _event, _key), do: socket

  defp refused(socket, refusal) do
    {level, message} = CalendarEditMessages.refusal(refusal)
    Flash.put_flash(socket, level, message)
  end

  defp failed(socket),
    do:
      Flash.put_flash(
        socket,
        :error,
        dgettext("dashboard_calendar", "Couldn't save that colour. Please try again.")
      )
end
