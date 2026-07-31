defmodule TymeslotWeb.Dashboard.Automation.Defaults do
  @moduledoc """
  Initial socket assigns for `TymeslotWeb.Dashboard.AutomationSettingsComponent`,
  one function per integration channel.

  Kept apart from the component so the three lists of starting values stay
  readable side by side and can be extended without growing the component.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Webhooks

  @doc """
  Assigns the webhook tab's starting state.
  """
  @spec assign_webhook_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
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

  @doc """
  Assigns the Telegram tab's starting state.
  """
  @spec assign_telegram_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
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

  @doc """
  Assigns the Slack tab's starting state.
  """
  @spec assign_slack_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
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
