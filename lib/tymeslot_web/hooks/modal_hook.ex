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

  @doc """
  Runs `fun` with the modal's data assign, guarding against duplicate confirm
  events.

  Confirm handlers read their `*_modal_data` assign and dereference it, then
  call `hide_modal/2` on success — which resets that assign to `nil`. A queued
  duplicate confirm event (double-click, or Enter pressed twice before the
  button disables) would otherwise read `nil` and crash with a `BadMapError`.

  This helper centralises the guard for every modal: when the data is already
  gone the confirmation has been handled, so the stray event becomes a harmless
  `{:noreply, socket}` no-op. Otherwise `fun` is invoked with the present data
  and its result is returned verbatim.
  """
  @spec with_modal_data(Phoenix.LiveView.Socket.t(), atom() | String.t(), (term() -> result)) ::
          result | {:noreply, Phoenix.LiveView.Socket.t()}
        when result: term()
  def with_modal_data(socket, modal_name, fun) when is_function(fun, 1) do
    {_show_key, data_key} = resolve_keys(modal_name)

    case socket.assigns[data_key] do
      nil -> {:noreply, socket}
      data -> fun.(data)
    end
  end

  @spec reset_modal_state(Phoenix.LiveView.Socket.t(), atom() | String.t()) ::
          Phoenix.LiveView.Socket.t()
  def reset_modal_state(socket, modal_name) do
    socket
    |> hide_modal(modal_name)
    |> Component.assign(:form_errors, %{})
    |> Component.assign(:saving, false)
  end

  @modal_registry %{
    delete_break: {:show_delete_break_modal, :delete_break_modal_data},
    clear_day: {:show_clear_day_modal, :clear_day_modal_data},
    cancel_meeting: {:show_cancel_meeting_modal, :cancel_meeting_modal_data},
    reschedule_request: {:show_reschedule_request_modal, :reschedule_request_modal_data},
    delete_meeting_type: {:show_delete_meeting_type_modal, :delete_meeting_type_modal_data},
    delete_avatar: {:show_delete_avatar_modal, :delete_avatar_modal_data},
    delete: {:show_delete_modal, :delete_modal_data},
    create: {:show_create_modal, :create_modal_data},
    edit: {:show_edit_modal, :edit_modal_data},
    deliveries: {:show_deliveries_modal, :deliveries_modal_data},
    regenerate_token: {:show_regenerate_token_modal, :regenerate_token_modal_data},
    telegram_delete: {:show_telegram_delete_modal, :telegram_delete_modal_data},
    telegram_deliveries: {:show_telegram_deliveries_modal, :telegram_deliveries_modal_data},
    slack_delete: {:show_slack_delete_modal, :slack_delete_modal_data},
    slack_deliveries: {:show_slack_deliveries_modal, :slack_deliveries_modal_data}
  }

  defp resolve_keys(k) when is_atom(k) do
    case Map.fetch(@modal_registry, k) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Unknown modal name: #{inspect(k)}"
    end
  end

  defp resolve_keys(k) when is_binary(k), do: resolve_keys(String.to_existing_atom(k))

  defp resolve_keys(other), do: raise(ArgumentError, "Unknown modal name: #{inspect(other)}")
end
