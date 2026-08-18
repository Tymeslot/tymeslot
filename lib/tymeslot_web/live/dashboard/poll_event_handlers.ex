defmodule TymeslotWeb.Dashboard.PollEventHandlers do
  @moduledoc """
  Routes poll-related `handle_info/2` messages for `DashboardLive`.

  Both messages arrive at the LiveView because it owns the process that
  subscribed on the host's behalf, but neither touches LiveView state: each
  simply forwards to `PollsComponent`. Keeping the routing here leaves
  `DashboardLive` focused on lifecycle and rendering.
  """

  import Phoenix.LiveView, only: [send_update: 2]

  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.Polls.PollsComponent

  @doc """
  A poll's votes or lifecycle changed. Routes it to the Polls component,
  which refreshes the on-screen results.
  """
  @spec handle_poll_updated(Ecto.UUID.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_poll_updated(poll_id, socket) do
    send_update(PollsComponent, id: component_id(), poll_updated: poll_id)
    {:noreply, socket}
  end

  @doc """
  The Polls component's advisory slot-health check runs in a supervised task
  and reports back to the LiveView; this routes it to the component.
  """
  @spec handle_poll_slot_health(Ecto.UUID.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_poll_slot_health(poll_id, health, socket) do
    send_update(PollsComponent, id: component_id(), poll_slot_health: {poll_id, health})
    {:noreply, socket}
  end

  defp component_id, do: ComponentDispatch.component_id(:polls)
end
