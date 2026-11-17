defmodule TymeslotWeb.Dashboard.Calendar.ReloadQueue do
  @moduledoc """
  The calendar surface's coalesced reloads. A sync cycle sends several
  messages in a burst; they are coalesced into one reload after a short
  delay. What the reload covers is the widest of the actions asked for:
  `:events_updated` and `:refresh_guest_summaries` need only the events.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update_after: 3]

  @delay 250

  # The parent's refresh messages (see `CalendarEventHandlers`): a sync
  # finished, events changed elsewhere, a refresh fell back on its timer, or
  # a guest answered an invitation (a booking's guests load with the events).
  @refresh_actions [
    :events_updated,
    :integration_synced,
    :refresh_events,
    :refresh_guest_summaries
  ]

  @doc "The actions the parent sends to ask for a reload."
  @spec refresh_actions() :: [atom()]
  def refresh_actions, do: @refresh_actions

  @doc "The delay, in milliseconds, before a queued reload runs."
  @spec delay() :: pos_integer()
  def delay, do: @delay

  @doc "Queues a reload of `module`'s component for `action`, or widens the one queued."
  @spec schedule(Phoenix.LiveView.Socket.t(), module(), atom()) :: Phoenix.LiveView.Socket.t()
  def schedule(%{assigns: %{pending_reload: nil}} = socket, module, action) do
    send_update_after(module, [id: socket.assigns.id, action: :reload], @delay)
    assign(socket, :pending_reload, scope(action))
  end

  def schedule(%{assigns: %{pending_reload: scope}} = socket, _module, action),
    do: assign(socket, :pending_reload, widest(scope, scope(action)))

  defp scope(action) when action in [:events_updated, :refresh_guest_summaries], do: :events
  defp scope(_action), do: :full

  defp widest(:full, _scope), do: :full
  defp widest(_scope, other), do: other
end
