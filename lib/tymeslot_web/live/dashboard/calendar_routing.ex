defmodule TymeslotWeb.Dashboard.CalendarRouting do
  @moduledoc """
  Hands the calendar messages `DashboardLive` receives to the calendar
  surface while the organiser is on the calendar page. Once they have left
  it nothing is sent: the LiveView's write guardian drives any queued writes
  (`Tymeslot.CalendarGrid.WriteGuardian.detach/0`) and hears every result
  itself, and a surface LiveView has yet to delete must not drive the same
  queue a second time.
  """

  import Phoenix.LiveView, only: [send_update: 2]

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  @id "calendar"

  @doc "Whether the calendar is on screen."
  @spec surface_on_screen?(Phoenix.LiveView.Socket.t()) :: boolean()
  def surface_on_screen?(socket), do: socket.assigns.live_action == :calendar

  @doc "Hands `assigns`, which carry an `:action`, to the calendar on screen."
  @spec to_mounted(Phoenix.LiveView.Socket.t(), keyword()) :: :ok
  def to_mounted(socket, assigns) do
    if surface_on_screen?(socket), do: send_update(CalendarSurface, [{:id, @id} | assigns])
    :ok
  end

  @doc """
  A sync finished or events changed elsewhere. `extra` (such as the
  integration whose sync finished) goes with the action.
  """
  @spec refresh(Phoenix.LiveView.Socket.t(), atom(), keyword()) :: :ok
  def refresh(socket, action, extra \\ []),
    do: to_mounted(socket, [action: action] ++ extra)

  @doc """
  The organiser's availability changed (`Tymeslot.Availability.changed/1`):
  the calendar reloads its bookable layer.
  """
  @spec bookable_changed(Phoenix.LiveView.Socket.t()) :: :ok
  def bookable_changed(socket), do: to_mounted(socket, action: :bookable_changed)

  @doc "An integration's sync failed or was discarded: the calendar marks the account."
  @spec sync_failed(Phoenix.LiveView.Socket.t(), integer()) :: :ok
  def sync_failed(socket, integration_id),
    do: to_mounted(socket, action: :integration_sync_failed, integration_id: integration_id)

  @doc "A delete scheduled from the calendar ended."
  @spec delete_settled(Phoenix.LiveView.Socket.t(), pos_integer(), term()) :: :ok
  def delete_settled(socket, token, outcome),
    do: to_mounted(socket, action: :delete_settled, token: token, outcome: outcome)

  @doc """
  A create the calendar started has an answer for its draft `draft_id`,
  titled `title`. Off the calendar page the answer is `:off_screen`, for the
  LiveView to tell the organiser itself.
  """
  @spec create_settled(Phoenix.LiveView.Socket.t(), String.t(), String.t(), term()) ::
          :ok | :off_screen
  def create_settled(socket, draft_id, title, result) do
    if surface_on_screen?(socket) do
      to_mounted(socket, action: :create_settled, draft: draft_id, title: title, result: result)
    else
      :off_screen
    end
  end

  @doc """
  A booking move the calendar started (`Calendar.BookingMove`) answered.
  Off the calendar page the answer is `:off_screen`, for the LiveView to
  tell the organiser itself.
  """
  @spec booking_move_settled(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), term()) ::
          :ok | :off_screen
  def booking_move_settled(socket, meeting_id, result) do
    if surface_on_screen?(socket) do
      to_mounted(socket, action: :booking_move_settled, meeting_id: meeting_id, result: result)
    else
      :off_screen
    end
  end

  @doc "A delete was scheduled in another tab of the organiser."
  @spec delete_scheduled(Phoenix.LiveView.Socket.t(), pos_integer(), map(), atom()) :: :ok
  def delete_scheduled(socket, token, address, scope),
    do:
      to_mounted(socket,
        action: :delete_scheduled,
        token: token,
        address: address,
        scope: scope
      )

  @doc "A scheduled delete was undone, in another tab or this one."
  @spec delete_cancelled(Phoenix.LiveView.Socket.t(), pos_integer()) :: :ok
  def delete_cancelled(socket, token),
    do: to_mounted(socket, action: :delete_cancelled, token: token)
end
