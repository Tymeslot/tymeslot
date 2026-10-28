defmodule TymeslotWeb.Hooks.ModalHook do
  @moduledoc """
  Shared hook for modal state management across LiveView components.
  Provides consistent modal state handling and reduces duplication.
  """

  alias Phoenix.Component

  @typedoc """
  A modal Core registers, by name (atom or string), or the
  `{show_key, data_key}` assigns of one it does not.
  """
  @type modal_name :: atom() | String.t() | {atom(), atom()}

  @spec mount_modal(Phoenix.LiveView.Socket.t(), list({modal_name(), boolean()})) ::
          Phoenix.LiveView.Socket.t()
  def mount_modal(socket, modal_configs) do
    Enum.reduce(modal_configs, socket, fn {modal_name, initial_state}, acc ->
      {show_key, data_key} = resolve_keys(modal_name)

      acc
      |> Component.assign(show_key, initial_state)
      |> Component.assign(data_key, nil)
    end)
  end

  @spec show_modal(Phoenix.LiveView.Socket.t(), modal_name(), any()) ::
          Phoenix.LiveView.Socket.t()
  def show_modal(socket, modal_name, data \\ nil) do
    {show_key, data_key} = resolve_keys(modal_name)

    socket
    |> Component.assign(show_key, true)
    |> Component.assign(data_key, data)
  end

  @spec hide_modal(Phoenix.LiveView.Socket.t(), modal_name()) ::
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
  @spec with_modal_data(Phoenix.LiveView.Socket.t(), modal_name(), (term() -> result)) ::
          result | {:noreply, Phoenix.LiveView.Socket.t()}
        when result: term()
  def with_modal_data(socket, modal_name, fun) when is_function(fun, 1) do
    {_show_key, data_key} = resolve_keys(modal_name)

    case socket.assigns[data_key] do
      nil -> {:noreply, socket}
      data -> fun.(data)
    end
  end

  @modal_registry %{
    delete_break: {:show_delete_break_modal, :delete_break_modal_data},
    clear_day: {:show_clear_day_modal, :clear_day_modal_data},
    schedule_form: {:show_schedule_form_modal, :schedule_form_modal_data},
    delete_schedule: {:show_delete_schedule_modal, :delete_schedule_modal_data},
    time_off_form: {:show_time_off_form_modal, :time_off_form_modal_data},
    delete_time_off: {:show_delete_time_off_modal, :delete_time_off_modal_data},
    cancel_meeting: {:show_cancel_meeting_modal, :cancel_meeting_modal_data},
    reschedule_request: {:show_reschedule_request_modal, :reschedule_request_modal_data},
    decline_request: {:show_decline_request_modal, :decline_request_modal_data},
    add_guests: {:show_add_guests_modal, :add_guests_modal_data},
    delete_meeting_type: {:show_delete_meeting_type_modal, :delete_meeting_type_modal_data},
    delete_avatar: {:show_delete_avatar_modal, :delete_avatar_modal_data},
    calendar_move: {:show_calendar_move_modal, :calendar_move_modal_data},
    delete: {:show_delete_modal, :delete_modal_data},
    create: {:show_create_modal, :create_modal_data},
    edit: {:show_edit_modal, :edit_modal_data},
    deliveries: {:show_deliveries_modal, :deliveries_modal_data},
    regenerate_token: {:show_regenerate_token_modal, :regenerate_token_modal_data},
    telegram_delete: {:show_telegram_delete_modal, :telegram_delete_modal_data},
    telegram_deliveries: {:show_telegram_deliveries_modal, :telegram_deliveries_modal_data},
    slack_delete: {:show_slack_delete_modal, :slack_delete_modal_data},
    slack_deliveries: {:show_slack_deliveries_modal, :slack_deliveries_modal_data},
    slug: {:show_slug_modal, :slug_modal_data},
    cancel: {:show_cancel_modal, :cancel_modal_data},
    skip: {:show_skip_modal, :skip_modal_data},
    skip_calendar: {:show_skip_calendar_modal, :skip_calendar_modal_data},
    theme_preview: {:show_theme_preview_modal, :theme_preview_modal_data},
    disconnect: {:show_disconnect_modal, :disconnect_modal_data},
    refund: {:show_refund_modal, :refund_modal_data}
  }

  # A modal Core does not register (one of SaaS's) names its own keys.
  defp resolve_keys({show_key, data_key} = keys) when is_atom(show_key) and is_atom(data_key),
    do: keys

  defp resolve_keys(k) when is_atom(k) do
    case Map.fetch(@modal_registry, k) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Unknown modal name: #{inspect(k)}"
    end
  end

  defp resolve_keys(k) when is_binary(k), do: resolve_keys(String.to_existing_atom(k))

  defp resolve_keys(other), do: raise(ArgumentError, "Unknown modal name: #{inspect(other)}")
end
