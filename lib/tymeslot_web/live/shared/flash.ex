defmodule TymeslotWeb.Live.Shared.Flash do
  @moduledoc """
  Standardised flash message handling for LiveView components.

  `Phoenix.LiveView.put_flash/3` only mutates the flash on the socket it
  receives — in a `Phoenix.LiveComponent` that is the component's own socket,
  which is never rendered with the flash container. The result is that any
  flash written from inside a component is silently dropped.

  This module provides a cleaner API for forwarding flash messages from
  LiveView components up to the parent LiveView, which owns the flash and
  actually renders it. Instead of calling `put_flash/3` inside a component,
  call one of the helpers here — they `send/2` a `{:flash, {type, message}}`
  message to the current process, which the parent LiveView handles via
  `handle_info/2`.

    ## Examples

      # Pipe-friendly — replaces `put_flash(socket, :error, msg)` inside
      # components without breaking the pipeline.
      socket
      |> assign(:submitting, false)
      |> Flash.put_flash(:error, "Something went wrong")

      # Fire-and-forget convenience helpers (return the message tuple).
      Flash.info("Settings saved successfully!")
      Flash.error("Failed to save settings")
      Flash.warning("This action cannot be undone")

      # Generic notify for dynamic types.
      Flash.notify(:info, "Custom message")
  """

  @type flash_type :: :info | :error | :warning

  @doc """
  Forwards a flash message to the parent LiveView and returns the socket
  unchanged so it can be used inside a pipeline.

  Use this instead of `Phoenix.LiveView.put_flash/3` anywhere the socket
  belongs to a `Phoenix.LiveComponent` (or to a function module that is
  reachable from one), otherwise the flash is silently dropped.

  The parent LiveView must handle `{:flash, {type, message}}` in
  `handle_info/2`.
  """
  @spec put_flash(Phoenix.LiveView.Socket.t(), flash_type(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def put_flash(socket, type, message)
      when type in [:info, :error, :warning] and is_binary(message) do
    notify(type, message)
    socket
  end

  @doc """
  Sends a flash message of the specified type to the current process.

  The message will be handled by the parent LiveView's handle_info/2 callback.
  """
  @spec notify(flash_type(), String.t()) :: {:flash, {flash_type(), String.t()}}
  def notify(type, message) when type in [:info, :error, :warning] and is_binary(message) do
    send(self(), {:flash, {type, message}})
  end

  @doc """
  Sends an info flash message.
  """
  @spec info(String.t()) :: {:flash, {:info, String.t()}}
  def info(message) when is_binary(message) do
    notify(:info, message)
  end

  @doc """
  Sends an error flash message.
  """
  @spec error(String.t()) :: {:flash, {:error, String.t()}}
  def error(message) when is_binary(message) do
    notify(:error, message)
  end

  @doc """
  Sends a warning flash message.
  """
  @spec warning(String.t()) :: {:flash, {:warning, String.t()}}
  def warning(message) when is_binary(message) do
    notify(:warning, message)
  end
end
