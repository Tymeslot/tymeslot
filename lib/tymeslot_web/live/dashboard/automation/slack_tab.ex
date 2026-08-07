defmodule TymeslotWeb.Dashboard.Automation.SlackTab do
  @moduledoc """
  Markup for the Slack tab of `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Rendering only: every interaction is pushed back to the owning LiveComponent
  through the `:myself` target passed in by the caller.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Automation.SlackCard
  alias TymeslotWeb.Dashboard.Automation.SlackEmptyState

  attr :integrations, :list, required: true
  attr :time_format, :string, required: true
  attr :slack_testing, :any, required: true
  attr :oauth_mode_available?, :boolean, required: true
  attr :myself, :any, required: true

  @spec slack_tab_content(map()) :: Phoenix.LiveView.Rendered.t()
  def slack_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header
            level={2}
            title={dgettext("dashboard_automation_chat", "Your Slack Integrations")}
            count={length(@integrations)}
          />
          <div class="flex items-center gap-3">
            <%= if @oauth_mode_available? do %>
              <.link href={~p"/api/slack/oauth/start"} class="btn-primary">
                {dgettext("dashboard_automation_chat", "Add to Slack")}
              </.link>
            <% end %>
            <button
              phx-click="slack_show_webhook_form"
              phx-target={@myself}
              class="btn-secondary"
            >
              {dgettext("dashboard_automation_chat", "Add via webhook URL")}
            </button>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <SlackCard.slack_card
              time_format={@time_format}
              integration={integration}
              testing={@slack_testing == integration.id}
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
      <SlackEmptyState.slack_empty_state
        oauth_mode_available?={@oauth_mode_available?}
        oauth_start_path={~p"/api/slack/oauth/start"}
        on_use_webhook_url={JS.push("slack_show_webhook_form", target: @myself)}
      />
    <% end %>
    """
  end
end
