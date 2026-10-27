defmodule TymeslotWeb.Dashboard.PollEventHandlers do
  @moduledoc """
  Routes poll-related `handle_info/2` messages for `DashboardLive`.

  Each message arrives at the LiveView because it owns the process that
  subscribed on the host's behalf, and most simply forward to
  `PollsComponent`. The exception is the poll deadline timer: the LiveView
  owns it (`:poll_deadline_timer`), arming it at the deadline the component
  reports and cancelling it when the host leaves the Polls section, which a
  component cannot do for itself since it is never told it was removed.
  Keeping the routing here leaves `DashboardLive` focused on lifecycle and
  rendering.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update: 2]

  alias Tymeslot.Clock
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.Polls.PollsComponent
  alias TymeslotWeb.Live.Shared.PollDeadlineTimer

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

  @doc """
  The Polls component's deadline timer fired (see `PollDeadlineTimer`);
  this routes it to the component, which reloads and re-arms.
  """
  @spec handle_poll_deadline_reached(Ecto.UUID.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_poll_deadline_reached(poll_id, %{assigns: %{live_action: :polls}} = socket) do
    send_update(PollsComponent, id: component_id(), poll_deadline_reached: poll_id)
    {:noreply, socket}
  end

  # Fired as the host left the section, before `keep_deadline_timer/2` could
  # cancel it: there is no component to tell.
  def handle_poll_deadline_reached(_poll_id, socket), do: {:noreply, socket}

  @doc """
  The Polls component reloaded and reports the next deadline among the polls
  on screen (`PollDeadlineTimer.next_deadline/2`); this arms the timer for
  it, keeping one already running for the same deadline. A report that
  arrives after the host has left the section is dropped.
  """
  @spec handle_poll_deadline_next(PollDeadlineTimer.deadline() | nil, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_poll_deadline_next(deadline, %{assigns: %{live_action: :polls}} = socket) do
    timer =
      PollDeadlineTimer.track(socket.assigns[:poll_deadline_timer], deadline, Clock.utc_now())

    {:noreply, assign(socket, :poll_deadline_timer, timer)}
  end

  def handle_poll_deadline_next(_deadline, socket), do: {:noreply, socket}

  @doc """
  Cancels the poll deadline timer when `action` is not the Polls section, so
  none is left armed for a component that is no longer on screen. Called on
  every navigation.
  """
  @spec keep_deadline_timer(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def keep_deadline_timer(socket, :polls), do: socket

  def keep_deadline_timer(socket, _action),
    do:
      assign(
        socket,
        :poll_deadline_timer,
        PollDeadlineTimer.cancel(socket.assigns[:poll_deadline_timer])
      )

  defp component_id, do: ComponentDispatch.component_id(:polls)
end
