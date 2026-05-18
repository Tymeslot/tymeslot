defmodule TymeslotWeb.Dashboard.Automation.SlackEventHandlers do
  @moduledoc """
  Public API facade — dispatches all Slack-prefixed LiveView events to grouped
  sub-modules. The automation settings component routes every `"slack_" <> _`
  event through `handle/3`, so callers never depend on the sub-module split.
  """

  alias TymeslotWeb.Dashboard.Automation.Slack.CrudHandlers
  alias TymeslotWeb.Dashboard.Automation.Slack.FormHandlers
  alias TymeslotWeb.Dashboard.Automation.Slack.ModalHandlers
  alias TymeslotWeb.Dashboard.Automation.Slack.StateHandlers

  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}

  # Form lifecycle ------------------------------------------------------------
  def handle("slack_show_webhook_form", params, socket),
    do: FormHandlers.handle_show_webhook_form(params, socket)

  def handle("slack_show_form", params, socket),
    do: FormHandlers.handle_show_form(params, socket)

  def handle("slack_close_form", params, socket),
    do: FormHandlers.handle_close_form(params, socket)

  def handle("slack_validate", params, socket),
    do: FormHandlers.handle_validate(params, socket)

  def handle("slack_validate_field", params, socket),
    do: FormHandlers.handle_validate_field(params, socket)

  def handle("slack_toggle_event", params, socket),
    do: FormHandlers.handle_toggle_event(params, socket)

  # CRUD ----------------------------------------------------------------------
  def handle("slack_save_webhook", params, socket),
    do: CrudHandlers.handle_save_webhook(params, socket)

  def handle("slack_save_channel", params, socket),
    do: CrudHandlers.handle_save_channel(params, socket)

  def handle("slack_update", params, socket),
    do: CrudHandlers.handle_update(params, socket)

  def handle("slack_show_edit_form", params, socket),
    do: CrudHandlers.handle_show_edit_form(params, socket)

  def handle("slack_show_channel_picker", params, socket),
    do: CrudHandlers.handle_show_channel_picker(params, socket)

  # State transitions ---------------------------------------------------------
  def handle("slack_toggle_active", params, socket),
    do: StateHandlers.handle_toggle_active(params, socket)

  def handle("slack_test", params, socket),
    do: StateHandlers.handle_test(params, socket)

  def handle("slack_disconnect", params, socket),
    do: StateHandlers.handle_disconnect(params, socket)

  def handle("slack_reconnect", params, socket),
    do: StateHandlers.handle_reconnect(params, socket)

  def handle("slack_reenable", params, socket),
    do: StateHandlers.handle_reenable(params, socket)

  # Modals --------------------------------------------------------------------
  def handle("slack_confirm_delete", params, socket),
    do: ModalHandlers.handle_show_delete_modal(params, socket)

  def handle("slack_hide_delete", params, socket),
    do: ModalHandlers.handle_hide_delete_modal(params, socket)

  def handle("slack_delete", params, socket),
    do: ModalHandlers.handle_delete(params, socket)

  def handle("slack_show_deliveries", params, socket),
    do: ModalHandlers.handle_show_deliveries(params, socket)

  def handle("slack_hide_deliveries", params, socket),
    do: ModalHandlers.handle_hide_deliveries(params, socket)
end
