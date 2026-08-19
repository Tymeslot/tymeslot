defmodule TymeslotWeb.Themes.Core.EventBus do
  @moduledoc """
  Event-driven communication system for themes.

  This module provides a decoupled way for themes to communicate with
  the rest of the system using Phoenix.PubSub.
  """

  alias Phoenix.PubSub

  @pubsub_name Tymeslot.PubSub

  @type event :: atom()
  @type payload :: map()
  @type theme_id :: String.t()

  @all_events ~w(theme_mounted)a

  @doc """
  Emits a theme event to all subscribers.
  """
  @spec emit(theme_id(), event(), payload()) :: :ok
  def emit(theme_id, event, payload \\ %{}) when event in @all_events do
    topic = theme_topic(theme_id)
    message = build_message(theme_id, event, payload)

    PubSub.broadcast(@pubsub_name, topic, message)

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
  Handles an incoming theme event in a LiveView.

  Use this in your handle_info callback:

      def handle_info({:theme_event, event}, socket) do
        socket = EventBus.handle_event(event, socket)
        {:noreply, socket}
      end

  No event currently changes the socket. `:theme_mounted` is the only event
  any code emits, and nothing acts on it, so this returns the socket
  untouched. Give an event a clause here when something needs to react to it.
  """
  @spec handle_event(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_event(%{event: _event, payload: _payload}, socket), do: socket

  @doc """
  Emits a standard lifecycle event when a theme is mounted.
  """
  @spec emit_theme_mounted(theme_id(), map()) :: :ok
  def emit_theme_mounted(theme_id, metadata \\ %{}) do
    emit(theme_id, :theme_mounted, Map.put(metadata, :timestamp, DateTime.utc_now()))
  end

  # Private functions

  defp theme_topic(theme_id), do: "theme:#{theme_id}"

  defp build_message(theme_id, event, payload) do
    {:theme_event,
     %{
       theme_id: theme_id,
       event: event,
       payload: payload,
       timestamp: DateTime.utc_now()
     }}
  end
end
