defmodule TymeslotWeb.Themes.Shared.Journey.Ambient do
  @moduledoc """
  Events that belong to no fact: the timezone picker's. They change how the
  page shows times, not what the booking holds, so the engine accepts them
  from every moment on screen, never from an outcome
  (`Journey.Runtime.handle_step_event/4`).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.{AvailabilityHelpers, NextAvailable, WeekSlots}
  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent
  alias TymeslotWeb.Themes.Shared.EventHandlers

  @events [
    :change_timezone,
    :search_timezone,
    :toggle_timezone_dropdown,
    :close_timezone_dropdown
  ]

  @doc "The ambient events, canonical names as `StepEvents.message/2` relays them."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "Handles one ambient event."
  @spec handle(Socket.t(), atom(), term()) :: {:noreply, Socket.t()}
  def handle(socket, :change_timezone, data), do: change_timezone(socket, data)

  def handle(socket, :search_timezone, data),
    do: EventHandlers.handle_timezone_search(socket, data)

  def handle(socket, :toggle_timezone_dropdown, _data),
    do:
      {:noreply,
       assign(socket, :timezone_dropdown_open, !socket.assigns[:timezone_dropdown_open])}

  def handle(socket, :close_timezone_dropdown, _data) do
    Process.send_after(self(), :close_dropdown, 150)
    {:noreply, socket}
  end

  # The picker's choice goes through `TimezoneHandlerComponent`, which switches
  # the zone. A zone that actually changed then decides which day stays
  # selected (`NextAvailable.follow_timezone_change/1`), reloads that day's
  # slots in the new zone, if one is left, and refetches the month, whose days
  # are worked out in the visitor's timezone. A week view's week is fetched
  # again too, for the times in the new zone. The slots are reloaded only after
  # the day is settled, so none are fetched for a day about to be dropped. An
  # invalid choice leaves `:user_timezone`, and so everything else, as it was.
  defp change_timezone(socket, data) do
    previous = socket.assigns[:user_timezone]

    case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
      {:ok, %Socket{assigns: %{user_timezone: ^previous}} = unchanged} ->
        {:noreply, unchanged}

      {:ok, updated_socket} ->
        socket =
          updated_socket
          |> NextAvailable.follow_timezone_change()
          |> AvailabilityHelpers.fetch_month_availability_async()
          |> WeekSlots.refetch()

        {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
        {:noreply, socket}
    end
  end
end
