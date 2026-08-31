defmodule TymeslotWeb.Themes.Core.EventBus do
  @moduledoc """
  Former event-driven communication system for themes.

  `:theme_mounted` was the only event ever emitted, and `handle_event/2`
  never acted on it. Actually wiring it up would have subscribed every
  visitor of every theme to one global `PubSub` topic (`"theme:<id>"`, not
  scoped per organiser) and broadcast onto it on every mount, which is O(N)
  wakeups per page load for a message every listener discards. Rather than
  pay that fan-out for a value nothing consumes, every function here is now
  a no-op that keeps the call sites (which subscribe/emit on mount) and
  their return-value contracts unchanged.
  """

  @type event :: atom()
  @type payload :: map()
  @type theme_id :: String.t()

  @doc """
  No-op. See the moduledoc: this used to broadcast `:theme_mounted` to a
  global per-theme PubSub topic that nothing consumed.
  """
  @spec emit(theme_id(), event(), payload()) :: :ok
  def emit(_theme_id, _event, _payload \\ %{}), do: :ok

  @doc """
  No-op. See the moduledoc: this used to subscribe to a global per-theme
  PubSub topic that nothing consumed.
  """
  @spec subscribe_to_theme(theme_id()) :: :ok
  def subscribe_to_theme(_theme_id), do: :ok

  @doc """
  No-op. Kept only so a stray `{:theme_event, _}` message (from before this
  module stopped subscribing) is still handled harmlessly rather than
  crashing an already-connected LiveView.
  """
  @spec handle_event(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_event(%{event: _event, payload: _payload}, socket), do: socket

  @doc """
  No-op. See the moduledoc: this used to emit `:theme_mounted` to a global
  per-theme PubSub topic that nothing consumed.
  """
  @spec emit_theme_mounted(theme_id(), map()) :: :ok
  def emit_theme_mounted(_theme_id, _metadata \\ %{}), do: :ok
end
