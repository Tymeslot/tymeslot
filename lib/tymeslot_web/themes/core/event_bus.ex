defmodule TymeslotWeb.Themes.Core.EventBus do
  @moduledoc """
  Event-driven communication system for themes.

  This module provides a decoupled way for themes to communicate with
  the rest of the system using Phoenix.PubSub.
  """

  alias Phoenix.Component
  alias Phoenix.PubSub
  alias TymeslotWeb.Themes.Core.Context
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: ThemeCustomizationHelpers

  @pubsub_name Tymeslot.PubSub

  @type event :: atom()
  @type payload :: map()
  @type theme_id :: String.t()

  # Theme lifecycle events
  @lifecycle_events ~w(theme_mounted theme_unmounted theme_switched theme_error)a

  # User interaction events
  @interaction_events ~w(step_changed booking_started booking_completed booking_cancelled)a

  # System events
  @system_events ~w(customization_changed capability_requested data_refreshed)a

  @all_events @lifecycle_events ++ @interaction_events ++ @system_events

  @doc """
  Emits a theme event to all subscribers.
  """
  @spec emit(theme_id(), event(), payload()) :: :ok
  def emit(theme_id, event, payload \\ %{}) when event in @all_events do
    topic = theme_topic(theme_id)
    message = build_message(theme_id, event, payload)

    PubSub.broadcast(@pubsub_name, topic, message)
    PubSub.broadcast(@pubsub_name, global_topic(), message)

    :ok
  end

  @doc """
  Subscribes to events for a specific theme.
  """
  @spec subscribe_to_theme(theme_id()) :: :ok | {:error, term()}
  def subscribe_to_theme(theme_id) do
    PubSub.subscribe(@pubsub_name, theme_topic(theme_id))
  end

  @doc """
  Subscribes to all theme events globally.
  """
  @spec subscribe_globally() :: :ok | {:error, term()}
  def subscribe_globally do
    PubSub.subscribe(@pubsub_name, global_topic())
  end

  @doc """
  Unsubscribes from theme events.
  """
  @spec unsubscribe_from_theme(theme_id()) :: :ok
  def unsubscribe_from_theme(theme_id) do
    PubSub.unsubscribe(@pubsub_name, theme_topic(theme_id))
  end

  @doc """
  Handles incoming theme events in a LiveView.

  Use this in your handle_info callback:

      def handle_info({:theme_event, event}, socket) do
        socket = EventBus.handle_event(event, socket)
        {:noreply, socket}
      end
  """
  @spec handle_event(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_event(%{event: event, payload: payload} = message, socket) do
    case event do
      :theme_switched ->
        handle_theme_switched(payload, socket)

      :customization_changed ->
        handle_customization_changed(payload, socket)

      :step_changed ->
        handle_step_changed(payload, socket)

      _ ->
        # Allow themes to handle custom events
        if function_exported?(socket.assigns.theme_module, :handle_theme_event, 2) do
          socket.assigns.theme_module.handle_theme_event(message, socket)
        else
          socket
        end
    end
  end

  @doc """
  Emits a standard lifecycle event when a theme is mounted.
  """
  @spec emit_theme_mounted(theme_id(), map()) :: :ok
  def emit_theme_mounted(theme_id, metadata \\ %{}) do
    emit(theme_id, :theme_mounted, Map.put(metadata, :timestamp, DateTime.utc_now()))
  end

  @doc """
  Emits a standard lifecycle event when a theme is unmounted.
  """
  @spec emit_theme_unmounted(theme_id(), map()) :: :ok
  def emit_theme_unmounted(theme_id, metadata \\ %{}) do
    emit(theme_id, :theme_unmounted, Map.put(metadata, :timestamp, DateTime.utc_now()))
  end

  @doc """
  Emits a navigation event when theme step changes.
  """
  @spec emit_step_changed(theme_id(), atom(), atom(), map()) :: :ok
  def emit_step_changed(theme_id, from_step, to_step, metadata \\ %{}) do
    payload =
      Map.merge(metadata, %{
        from_step: from_step,
        to_step: to_step,
        timestamp: DateTime.utc_now()
      })

    emit(theme_id, :step_changed, payload)
  end

  # Private functions

  defp theme_topic(theme_id), do: "theme:#{theme_id}"
  defp global_topic, do: "theme:global"

  defp build_message(theme_id, event, payload) do
    {:theme_event,
     %{
       theme_id: theme_id,
       event: event,
       payload: payload,
       timestamp: DateTime.utc_now()
     }}
  end

  defp handle_theme_switched(%{new_theme_id: new_theme_id}, socket) do
    # Reload theme context when theme is switched
    if socket.assigns[:organizer_profile] do
      case Context.new(new_theme_id, socket.assigns.organizer_profile) do
        %Context{} = context ->
          Context.assign_to_socket(socket, context)

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp handle_customization_changed(%{theme_id: theme_id}, socket) do
    # Reload customizations when they change
    if socket.assigns[:theme_id] == theme_id && socket.assigns[:organizer_profile] do
      profile = socket.assigns.organizer_profile
      ThemeCustomizationHelpers.assign_theme_customization(socket, profile, theme_id)
    else
      socket
    end
  end

  defp handle_step_changed(%{to_step: step}, socket) do
    # Update current step in assigns
    Component.assign(socket, :current_step, step)
  end
end
