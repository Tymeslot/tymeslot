defmodule TymeslotWeb.Hooks.ModalHook do
  @moduledoc """
  Shared hook for modal state management across LiveView components.
  Provides consistent modal state handling and reduces duplication.
  """

  alias Phoenix.Component

  @spec mount_modal(Phoenix.LiveView.Socket.t(), list({atom(), boolean()})) ::
          Phoenix.LiveView.Socket.t()
  def mount_modal(socket, modal_configs) do
    Enum.reduce(modal_configs, socket, fn {modal_name, initial_state}, acc ->
      {show_key, data_key} = resolve_keys(modal_name)

      acc
      |> Component.assign(show_key, initial_state)
      |> Component.assign(data_key, nil)
    end)
  end

  @spec show_modal(Phoenix.LiveView.Socket.t(), atom() | String.t(), any()) ::
          Phoenix.LiveView.Socket.t()
  def show_modal(socket, modal_name, data \\ nil) do
    {show_key, data_key} = resolve_keys(modal_name)

    socket
    |> Component.assign(show_key, true)
    |> Component.assign(data_key, data)
  end

  @spec hide_modal(Phoenix.LiveView.Socket.t(), atom() | String.t()) ::
          Phoenix.LiveView.Socket.t()
  def hide_modal(socket, modal_name) do
    {show_key, data_key} = resolve_keys(modal_name)

    socket
    |> Component.assign(show_key, false)
    |> Component.assign(data_key, nil)
  end

  @spec reset_modal_state(Phoenix.LiveView.Socket.t(), atom() | String.t()) ::
          Phoenix.LiveView.Socket.t()
  def reset_modal_state(socket, modal_name) do
    socket
    |> hide_modal(modal_name)
    |> Component.assign(:form_errors, %{})
    |> Component.assign(:saving, false)
  end

  defp resolve_keys(:delete_break), do: {:show_delete_break_modal, :delete_break_modal_data}
  defp resolve_keys(:clear_day), do: {:show_clear_day_modal, :clear_day_modal_data}
  defp resolve_keys(:cancel_meeting), do: {:show_cancel_meeting_modal, :cancel_meeting_modal_data}

  defp resolve_keys(:reschedule_request),
    do: {:show_reschedule_request_modal, :reschedule_request_modal_data}

  defp resolve_keys(:delete_meeting_type),
    do: {:show_delete_meeting_type_modal, :delete_meeting_type_modal_data}

  defp resolve_keys(:delete_avatar), do: {:show_delete_avatar_modal, :delete_avatar_modal_data}
  defp resolve_keys(:delete), do: {:show_delete_modal, :delete_modal_data}

  defp resolve_keys("delete_break"), do: {:show_delete_break_modal, :delete_break_modal_data}
  defp resolve_keys("clear_day"), do: {:show_clear_day_modal, :clear_day_modal_data}

  defp resolve_keys("cancel_meeting"),
    do: {:show_cancel_meeting_modal, :cancel_meeting_modal_data}

  defp resolve_keys("reschedule_request"),
    do: {:show_reschedule_request_modal, :reschedule_request_modal_data}

  defp resolve_keys("delete_meeting_type"),
    do: {:show_delete_meeting_type_modal, :delete_meeting_type_modal_data}

  defp resolve_keys("delete_avatar"), do: {:show_delete_avatar_modal, :delete_avatar_modal_data}
  defp resolve_keys("delete"), do: {:show_delete_modal, :delete_modal_data}

  defp resolve_keys(other), do: raise(ArgumentError, "Unknown modal name: #{inspect(other)}")
end
