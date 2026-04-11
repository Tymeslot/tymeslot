defmodule TymeslotWeb.Dashboard.Automation.TelegramEventHandlers do
  @moduledoc """
  Public API facade — delegates all Telegram event handler calls to grouped
  sub-modules. Callers interact only with this module; sub-modules are
  implementation details.
  """

  alias TymeslotWeb.Dashboard.Automation.Telegram.CrudHandlers
  alias TymeslotWeb.Dashboard.Automation.Telegram.FormHandlers
  alias TymeslotWeb.Dashboard.Automation.Telegram.ModalHandlers
  alias TymeslotWeb.Dashboard.Automation.Telegram.StateHandlers

  defdelegate handle_show_form(params, socket), to: FormHandlers
  defdelegate handle_close_form(params, socket), to: FormHandlers
  defdelegate handle_refresh_link(params, socket), to: FormHandlers
  defdelegate handle_validate_field(params, socket), to: FormHandlers
  defdelegate handle_toggle_event(params, socket), to: FormHandlers

  defdelegate handle_create(params, socket), to: CrudHandlers
  defdelegate handle_update(params, socket), to: CrudHandlers
  defdelegate handle_show_edit_form(params, socket), to: CrudHandlers

  defdelegate handle_toggle(params, socket), to: StateHandlers
  defdelegate handle_test(params, socket), to: StateHandlers
  defdelegate handle_reenable(params, socket), to: StateHandlers
  defdelegate handle_disconnect(params, socket), to: StateHandlers
  defdelegate handle_reconnect(params, socket), to: StateHandlers

  defdelegate handle_show_delete_modal(params, socket), to: ModalHandlers
  defdelegate handle_hide_delete_modal(params, socket), to: ModalHandlers
  defdelegate handle_delete(params, socket), to: ModalHandlers
  defdelegate handle_show_deliveries(params, socket), to: ModalHandlers
  defdelegate handle_hide_deliveries(params, socket), to: ModalHandlers
  defdelegate handle_linked(socket, integration_id), to: ModalHandlers
  defdelegate handle_link_expired(socket, integration_id), to: ModalHandlers
end
