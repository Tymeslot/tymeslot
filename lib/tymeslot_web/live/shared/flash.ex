defmodule TymeslotWeb.Live.Shared.Flash do
  @moduledoc """
  Standardized flash message handling for LiveView components.

  This module provides a cleaner API for sending flash messages from LiveView
  components to their parent processes. Instead of manually sending messages
  with `send(self(), {:flash, {type, message}})`, you can use the convenience
  functions provided here.

  ## Examples

      alias TymeslotWeb.Live.Shared.Flash
      
      # Using convenience functions
      Flash.info("Settings saved successfully!")
      Flash.error("Failed to save settings")
      Flash.warning("This action cannot be undone")
      
      # Using the generic notify function
      Flash.notify(:info, "Custom message")
  """

  @type flash_type :: :info | :error | :warning

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
