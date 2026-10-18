defmodule TymeslotWeb.Dashboard.CalendarRouting do
  @moduledoc """
  Which calendar component a calendar message `DashboardLive` received goes
  to: the old grid or the new surface, whichever the organiser has on
  screen. After a switch that is the other surface, and only the one
  switched away from gets nothing; neither gets anything once the organiser
  has left the calendar page. Then the LiveView's write guardian drives any
  queued writes (`Tymeslot.CalendarGrid.WriteGuardian.detach/0`) and hears
  every result itself, and a calendar component LiveView has yet to delete
  must not drive the same queue a second time.
  """

  import Phoenix.LiveView, only: [send_update: 2]

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @id "calendar"

  @doc "Whether the old grid is on screen."
  @spec grid_on_screen?(Phoenix.LiveView.Socket.t()) :: boolean()
  def grid_on_screen?(socket),
    do: socket.assigns.live_action == :calendar and socket.assigns[:calendar_redesign] != true

  @doc "Whether the new surface is on screen."
  @spec surface_on_screen?(Phoenix.LiveView.Socket.t()) :: boolean()
  def surface_on_screen?(socket),
    do: socket.assigns.live_action == :calendar and socket.assigns[:calendar_redesign] == true

  @doc "Hands `assigns`, which carry an `:action`, to the calendar on screen."
  @spec to_mounted(Phoenix.LiveView.Socket.t(), keyword()) :: :ok
  def to_mounted(socket, assigns) do
    cond do
      grid_on_screen?(socket) -> send_update(CalendarGridComponent, [{:id, @id} | assigns])
      surface_on_screen?(socket) -> send_update(CalendarSurface, [{:id, @id} | assigns])
      true -> :ok
    end

    :ok
  end

  @doc """
  A sync finished or events changed elsewhere. `extra` (such as the
  integration whose sync finished) goes to the new surface only; the old
  grid's update handlers take the action alone.
  """
  @spec refresh(Phoenix.LiveView.Socket.t(), atom(), keyword()) :: :ok
  def refresh(socket, action, extra \\ []) do
    cond do
      grid_on_screen?(socket) ->
        send_update(CalendarGridComponent, id: @id, action: action)

      surface_on_screen?(socket) ->
        send_update(CalendarSurface, [id: @id, action: action] ++ extra)

      true ->
        :ok
    end

    :ok
  end

  @doc """
  The organiser's availability changed (`Tymeslot.Availability.changed/1`):
  the new surface reloads its bookable layer. The old grid has no layer.
  """
  @spec bookable_changed(Phoenix.LiveView.Socket.t()) :: :ok
  def bookable_changed(socket) do
    if surface_on_screen?(socket),
      do: send_update(CalendarSurface, id: @id, action: :bookable_changed)

    :ok
  end

  @doc """
  An integration's sync failed or was discarded. The old grid counts it as
  finished, which ends its "Syncing" banner; the new surface marks the
  account.
  """
  @spec sync_failed(Phoenix.LiveView.Socket.t(), integer()) :: :ok
  def sync_failed(socket, integration_id) do
    cond do
      grid_on_screen?(socket) ->
        send_update(CalendarGridComponent, id: @id, action: :integration_synced)

      surface_on_screen?(socket) ->
        send_update(CalendarSurface,
          id: @id,
          action: :integration_sync_failed,
          integration_id: integration_id
        )

      true ->
        :ok
    end

    :ok
  end

  @doc "A delete scheduled from the new surface ended."
  @spec delete_settled(Phoenix.LiveView.Socket.t(), pos_integer(), term()) :: :ok
  def delete_settled(socket, token, outcome) do
    if surface_on_screen?(socket),
      do:
        send_update(CalendarSurface,
          id: @id,
          action: :delete_settled,
          token: token,
          outcome: outcome
        )

    :ok
  end

  @doc """
  A create the new surface started has an answer for its draft `draft_id`,
  titled `title`. The old grid never starts one, so only the new surface
  hears it; with no new surface on screen the answer is `:off_screen`, for
  the LiveView to tell the organiser itself.
  """
  @spec create_settled(Phoenix.LiveView.Socket.t(), String.t(), String.t(), term()) ::
          :ok | :off_screen
  def create_settled(socket, draft_id, title, result) do
    if surface_on_screen?(socket) do
      send_update(CalendarSurface,
        id: @id,
        action: :create_settled,
        draft: draft_id,
        title: title,
        result: result
      )

      :ok
    else
      :off_screen
    end
  end

  @doc "A delete was scheduled in another tab of the organiser."
  @spec delete_scheduled(Phoenix.LiveView.Socket.t(), pos_integer(), map(), atom()) :: :ok
  def delete_scheduled(socket, token, address, scope) do
    if surface_on_screen?(socket),
      do:
        send_update(CalendarSurface,
          id: @id,
          action: :delete_scheduled,
          token: token,
          address: address,
          scope: scope
        )

    :ok
  end

  @doc "A scheduled delete was undone, in another tab or this one."
  @spec delete_cancelled(Phoenix.LiveView.Socket.t(), pos_integer()) :: :ok
  def delete_cancelled(socket, token) do
    if surface_on_screen?(socket),
      do: send_update(CalendarSurface, id: @id, action: :delete_cancelled, token: token)

    :ok
  end
end
