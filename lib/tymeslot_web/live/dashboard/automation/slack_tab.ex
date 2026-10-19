defmodule TymeslotWeb.Dashboard.Automation.SlackTab do
  @moduledoc """
  Markup for the Slack tab of `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Rendering only: every interaction is pushed back to the owning LiveComponent
  through the `:myself` target passed in by the caller.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.SlackCard

  attr :integrations, :list, required: true
  attr :time_format, :string, required: true
  attr :slack_testing, :any, required: true
  attr :oauth_mode_available?, :boolean, required: true
  attr :myself, :any, required: true

  attr :paused, :boolean,
    default: false,
    doc: "The owner's plan doesn't include automations: cards paused, nothing can be added"

  @spec slack_tab_content(map()) :: Phoenix.LiveView.Rendered.t()
  def slack_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <.section_header
          title={dgettext("dashboard_automation_chat", "Your Slack Integrations")}
          count={length(@integrations)}
        >
          <:actions>
            <.add_to_slack :if={@oauth_mode_available?} paused={@paused} />
            <.action_button
              variant={:secondary}
              disabled={@paused}
              phx-click={!@paused && "slack_show_webhook_form"}
              phx-target={@myself}
            >
              {dgettext("dashboard_automation_chat", "Add via webhook URL")}
            </.action_button>
          </:actions>
        </.section_header>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <SlackCard.slack_card
              time_format={@time_format}
              integration={integration}
              testing={@slack_testing == integration.id}
              paused={@paused}
              target={@myself}
              on_edit={
                JS.push("slack_show_edit_form", value: %{"id" => integration.id}, target: @myself)
              }
              on_delete={
                JS.push("slack_confirm_delete", value: %{"id" => integration.id}, target: @myself)
              }
              on_toggle="slack_toggle_active"
              on_test={JS.push("slack_test", value: %{"id" => integration.id}, target: @myself)}
              on_view_deliveries={
                JS.push("slack_show_deliveries", value: %{"id" => integration.id}, target: @myself)
              }
              on_reenable={
                JS.push("slack_reenable", value: %{"id" => integration.id}, target: @myself)
              }
              on_pick_channel={
                JS.push("slack_show_channel_picker",
                  value: %{"id" => integration.id},
                  target: @myself
                )
              }
              on_disconnect={
                JS.push("slack_disconnect", value: %{"id" => integration.id}, target: @myself)
              }
              on_reconnect={
                if @oauth_mode_available? do
                  JS.push("slack_reconnect", value: %{"id" => integration.id}, target: @myself)
                end
              }
            />
          <% end %>
        </div>
      </div>
    <% else %>
      <.empty_state
        size={:lg}
        tone={:brand}
        heading={:h2}
        title={dgettext("dashboard_automation_chat", "No Slack Integrations")}
        description={
          dgettext(
            "dashboard_automation_chat",
            "Connect Slack to receive instant notifications when meetings are booked, cancelled, or rescheduled."
          )
        }
      >
        <:graphic><IconComponents.icon name={:slack} class="w-10 h-10" /></:graphic>
        <:action :if={@oauth_mode_available?}>
          <.add_to_slack paused={@paused} icon />
          <.action_button
            variant={:secondary}
            disabled={@paused}
            phx-click={!@paused && "slack_show_webhook_form"}
            phx-target={@myself}
          >
            {dgettext("dashboard_automation_chat", "Add via webhook URL")}
          </.action_button>
        </:action>
        <:action :if={!@oauth_mode_available?}>
          <.action_button
            disabled={@paused}
            phx-click={!@paused && "slack_show_webhook_form"}
            phx-target={@myself}
          >
            {dgettext("dashboard_automation_chat", "Add Slack via Webhook URL")}
          </.action_button>
        </:action>
      </.empty_state>
    <% end %>
    """
  end

  attr :paused, :boolean, required: true
  attr :icon, :boolean, default: false

  # Starting OAuth while paused would only be refused at the callback, so the
  # link gives way to a disabled button carrying the same label.
  defp add_to_slack(%{paused: true} = assigns) do
    ~H"""
    <.action_button disabled>
      <IconComponents.icon :if={@icon} name={:slack} class="w-5 h-5" />
      {dgettext("dashboard_automation_chat", "Add to Slack")}
    </.action_button>
    """
  end

  defp add_to_slack(assigns) do
    ~H"""
    <.action_link href={~p"/api/slack/oauth/start"}>
      <IconComponents.icon :if={@icon} name={:slack} class="w-5 h-5" />
      {dgettext("dashboard_automation_chat", "Add to Slack")}
    </.action_link>
    """
  end
end
