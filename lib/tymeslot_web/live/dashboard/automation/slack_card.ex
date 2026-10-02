defmodule TymeslotWeb.Dashboard.Automation.SlackCard do
  @moduledoc false
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers

  attr :integration, :map, required: true
  attr :time_format, :string, required: true
  attr :testing, :boolean, default: false
  attr :target, :any, required: true
  attr :on_edit, :any, required: true
  attr :on_delete, :any, required: true
  attr :on_toggle, :string, required: true
  attr :on_test, :any, required: true
  attr :on_view_deliveries, :any, required: true
  attr :on_reenable, :any, default: nil
  attr :on_pick_channel, :any, default: nil
  attr :on_disconnect, :any, default: nil
  attr :on_reconnect, :any, default: nil

  @spec slack_card(map()) :: Phoenix.LiveView.Rendered.t()
  def slack_card(assigns) do
    status = SlackIntegrationSchema.status(assigns.integration)
    {tone, pulse, label} = status_presentation(status)

    assigns = assign(assigns, status: status, tone: tone, pulse: pulse, label: label)

    ~H"""
    <IntegrationCard.integration_card
      id={"#{@integration.id}"}
      title={@integration.name}
      status={{@tone, @label}}
      pulse={@pulse}
      summary={location_label(@integration)}
      active={@status != :paused and @status != :auto_disabled}
      toggle_event={if(@status in [:active, :paused], do: @on_toggle)}
      toggle_id={"slack-toggle-#{@integration.id}"}
      target={@target}
      tags={@integration.events}
      notice={notice(@status, @integration)}
      notice_tone={(@status == :auto_disabled && :danger) || :warning}
    >
      <:icon><IconComponents.icon name={:slack} class="w-6 h-6" /></:icon>
      <:last_activity :if={@status != :pending_oauth && @integration.last_triggered_at}>
        {dgettext("dashboard_automation_chat", "Last triggered: %{time}",
          time: AutomationHelpers.format_datetime(@integration.last_triggered_at, @time_format)
        )}
      </:last_activity>
      <:last_activity :if={@status != :pending_oauth && !@integration.last_triggered_at} muted>
        {dgettext("dashboard_automation_chat", "Never triggered")}
      </:last_activity>
      <:actions>
        <.action_button
          :if={@status == :pending_oauth && @on_pick_channel}
          size={:sm}
          phx-click={@on_pick_channel}
        >
          {dgettext("dashboard_automation_chat", "Pick a channel")}
        </.action_button>
        <%!-- Restarts OAuth from scratch for an install still waiting on a channel. --%>
        <.action_button
          :if={@status == :pending_oauth && @integration.app_mode == "oauth" && @on_reconnect}
          variant={:secondary}
          size={:sm}
          icon="hero-arrow-path"
          phx-click={@on_reconnect}
        >
          {dgettext("dashboard_automation_chat", "Reconnect")}
        </.action_button>
        <.loading_button
          :if={@status in [:active, :paused]}
          variant={:secondary}
          size={:sm}
          icon="hero-bolt"
          loading={@testing}
          loading_text={dgettext("dashboard_automation_chat", "Testing")}
          disabled={@status != :active}
          phx-click={@on_test}
        >
          {dgettext("dashboard_automation_chat", "Test")}
        </.loading_button>
        <.action_button
          :if={@status == :auto_disabled && @on_reenable}
          size={:sm}
          phx-click={@on_reenable}
        >
          {dgettext("dashboard_automation_chat", "Re-enable")}
        </.action_button>
        <.action_button
          :if={@status != :pending_oauth}
          variant={:secondary}
          size={:sm}
          icon="hero-document-text"
          phx-click={@on_view_deliveries}
        >
          {dgettext("dashboard_automation_chat", "Logs")}
        </.action_button>
      </:actions>
      <:end_actions>
        <.icon_button
          :if={@status != :pending_oauth}
          icon="hero-pencil-square"
          label={dgettext("dashboard_automation_chat", "Edit")}
          phx-click={@on_edit}
        />
        <%!-- OAuth installs only, once a channel is set. --%>
        <.icon_button
          :if={@on_disconnect && @integration.app_mode == "oauth" && @integration.channel_id}
          icon="hero-no-symbol"
          variant={:warning}
          label={dgettext("dashboard_automation_chat", "Disconnect Slack")}
          phx-click={@on_disconnect}
        />
        <.icon_button
          icon="hero-trash"
          variant={:danger}
          label={dgettext("dashboard_automation_chat", "Delete")}
          phx-click={@on_delete}
        />
      </:end_actions>
    </IntegrationCard.integration_card>
    """
  end

  defp status_presentation(:pending_oauth),
    do: {:warning, true, dgettext("dashboard_automation_chat", "Channel needed")}

  defp status_presentation(:active),
    do: {:success, false, dgettext("dashboard_automation_chat", "Active")}

  defp status_presentation(:paused),
    do: {:neutral, false, dgettext("dashboard_automation_chat", "Paused")}

  defp status_presentation(:auto_disabled),
    do: {:danger, false, dgettext("dashboard_automation_chat", "Disabled")}

  defp notice(:pending_oauth, _integration),
    do: dgettext("dashboard_automation_chat", "Pick a channel to finish setup.")

  defp notice(:auto_disabled, integration),
    do:
      dgettext("dashboard_automation_chat", "Disabled: %{reason}",
        reason: disabled_reason_label(integration.disabled_reason)
      )

  defp notice(_status, _integration), do: nil

  # Renders the human-readable destination for the integration: workspace and
  # channel for OAuth installs, or "Custom webhook" with channel hint for
  # pasted Incoming Webhook URLs.
  defp location_label(%{app_mode: "oauth"} = integration) do
    workspace = integration.team_name || dgettext("dashboard_automation_chat", "Slack workspace")

    case integration.channel_name do
      nil ->
        workspace

      channel ->
        dgettext("dashboard_automation_chat", "%{workspace} · #%{channel}",
          workspace: workspace,
          channel: String.trim_leading(channel, "#")
        )
    end
  end

  defp location_label(%{app_mode: "webhook_url"} = integration) do
    case integration.webhook_channel_hint do
      nil ->
        dgettext("dashboard_automation_chat", "Custom webhook")

      "" ->
        dgettext("dashboard_automation_chat", "Custom webhook")

      hint ->
        dgettext("dashboard_automation_chat", "Custom webhook · #%{channel}",
          channel: String.trim_leading(hint, "#")
        )
    end
  end

  defp location_label(_integration), do: "Slack"

  defp disabled_reason_label(nil), do: dgettext("dashboard_automation_chat", "auto-disabled")
  defp disabled_reason_label(""), do: dgettext("dashboard_automation_chat", "auto-disabled")

  defp disabled_reason_label("webhook_url_revoked"),
    do: dgettext("dashboard_automation_chat", "webhook URL was revoked in Slack")

  defp disabled_reason_label(reason) when is_binary(reason), do: reason
end
