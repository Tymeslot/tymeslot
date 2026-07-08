defmodule TymeslotWeb.Dashboard.AutomationSettingsDefaults do
  @moduledoc """
  Default socket assigns for the three automation channels (webhooks, Telegram,
  Slack). Extracted from `AutomationSettingsComponent` to keep that component
  focused on events and rendering.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Webhooks

  @spec assign_webhook_defaults(Socket.t()) :: Socket.t()
  def assign_webhook_defaults(socket) do
    socket
    |> assign(:webhooks, [])
    |> assign(:form_errors, %{})
    |> assign(:form_values, %{})
    |> assign(:saving, false)
    |> assign(:testing_connection, nil)
    |> assign(:webhook_to_delete, nil)
    |> assign(:selected_webhook, nil)
    |> assign(:deliveries, [])
    |> assign(:delivery_stats, nil)
    |> assign(:available_events, Webhooks.available_events())
    |> assign(:show_webhook_form, false)
    |> assign(:webhook_form_mode, :create)
    |> assign(:webhook_form_data, nil)
    |> assign(:webhook_form_timestamp, nil)
  end

  @spec assign_telegram_defaults(Socket.t()) :: Socket.t()
  def assign_telegram_defaults(socket) do
    socket
    |> assign(:telegram_integrations, [])
    |> assign(:telegram_form_errors, %{})
    |> assign(:telegram_form_values, %{})
    |> assign(:telegram_saving, false)
    |> assign(:telegram_testing, nil)
    |> assign(:telegram_to_delete, nil)
    |> assign(:selected_telegram, nil)
    |> assign(:telegram_deliveries, [])
    |> assign(:telegram_delivery_stats, nil)
    |> assign(:show_telegram_form, false)
    |> assign(:telegram_form_mode, :create)
    |> assign(:telegram_form_data, nil)
    |> assign(:telegram_form_timestamp, nil)
    |> assign(:telegram_wizard_step, 1)
    |> assign(:telegram_link_expired, false)
    |> assign(:telegram_link_timer, nil)
    |> assign(:telegram_deep_link, nil)
    |> assign(:telegram_form_is_stub, false)
    |> assign(:telegram_subscribed, false)
  end

  @spec assign_slack_defaults(Socket.t()) :: Socket.t()
  def assign_slack_defaults(socket) do
    socket
    |> assign(:slack_integrations, [])
    |> assign(:slack_form_errors, %{})
    |> assign(:slack_form_values, %{})
    |> assign(:slack_saving, false)
    |> assign(:slack_testing, nil)
    |> assign(:slack_to_delete, nil)
    |> assign(:selected_slack, nil)
    |> assign(:slack_deliveries, [])
    |> assign(:slack_delivery_stats, nil)
    |> assign(:show_slack_form, false)
    |> assign(:slack_form_mode, :webhook_url)
    |> assign(:slack_form_data, nil)
    |> assign(:slack_form_timestamp, nil)
    |> assign(:slack_pending_opened_for, nil)
  end
end
