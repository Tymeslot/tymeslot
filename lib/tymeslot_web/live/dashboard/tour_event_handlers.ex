defmodule TymeslotWeb.Dashboard.TourEventHandlers do
  @moduledoc """
  Handles the dashboard onboarding tour for `DashboardLive`.

  Owns the `tour:*` `handle_event/3` clauses and the helpers that advance,
  initialise, and dismiss the tour. `DashboardLive` delegates directly so
  the LiveView module stays focused on lifecycle and rendering.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth
  alias Tymeslot.Onboarding.DashboardTour

  @doc """
  Handles a `tour:<action>` event. The `action` is the portion of the event
  name after the `tour:` prefix.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("shown", _params, socket) do
    {:noreply, mark_tour_seen_once(socket)}
  end

  def handle_event("next", _params, socket) do
    {:noreply, advance_tour(socket)}
  end

  def handle_event("back", _params, socket) do
    prev = max(socket.assigns.tour_step_index - 1, 0)
    {:noreply, assign(socket, :tour_step_index, prev)}
  end

  def handle_event("skip", _params, socket) do
    {:noreply, socket |> mark_tour_seen_once() |> assign(:tour_active, false)}
  end

  def handle_event("finish", _params, socket) do
    {:noreply, socket |> mark_tour_seen_once() |> assign(:tour_active, false)}
  end

  def handle_event("skip-step", _params, socket) do
    {:noreply, advance_tour(socket)}
  end

  def handle_event("viewport-too-small", _params, socket) do
    {:noreply, assign(socket, :tour_active, false)}
  end

  # Catch-all for unknown `tour:*` actions. A client pushing an unrecognised
  # event must never crash the user's own LiveView, so we no-op rather than
  # raise FunctionClauseError.
  def handle_event(_action, _params, socket) do
    {:noreply, socket}
  end

  @doc """
  Initialises tour assigns for the current action. Only the `:overview`
  action activates the tour, and only for users who haven't seen it yet.
  """
  @spec assign_tour_state(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def assign_tour_state(socket, :overview) do
    user = socket.assigns[:current_user]

    if user && !Auth.dashboard_tour_seen?(user) do
      socket
      |> assign(:tour_active, true)
      |> assign(:tour_step_index, 0)
      |> assign(:tour_total_steps, DashboardTour.count())
    else
      socket
      |> assign(:tour_active, false)
      |> assign(:tour_step_index, 0)
      |> assign(:tour_total_steps, 0)
    end
  end

  def assign_tour_state(socket, _other_action) do
    socket
    |> assign(:tour_active, false)
    |> assign(:tour_step_index, 0)
    |> assign(:tour_total_steps, 0)
  end

  defp advance_tour(socket) do
    next = socket.assigns.tour_step_index + 1

    if next >= socket.assigns.tour_total_steps do
      assign(socket, :tour_active, false)
    else
      assign(socket, :tour_step_index, next)
    end
  end

  defp mark_tour_seen_once(socket) do
    user = socket.assigns[:current_user]

    if user && !Auth.dashboard_tour_seen?(user) do
      case Auth.mark_dashboard_tour_seen(user) do
        {:ok, updated_user} ->
          assign(socket, :current_user, updated_user)

        {:error, _changeset} ->
          # Already-marked or transient DB issue — leave the user alone but
          # still dismiss the tour to avoid loops. The next visit will re-check.
          socket
      end
    else
      socket
    end
  end
end
