defmodule TymeslotWeb.Dashboard.Automation.TelegramTab do
  @moduledoc """
  Markup for the Telegram tab of `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Rendering only: every interaction is pushed back to the owning LiveComponent
  through the `:myself` target passed in by the caller.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Automation.TelegramCard
  alias TymeslotWeb.Dashboard.Automation.TelegramEmptyState

  attr :integrations, :list, required: true
  attr :time_format, :string, required: true
  attr :telegram_testing, :any, required: true
  attr :myself, :any, required: true

  @spec telegram_tab_content(map()) :: Phoenix.LiveView.Rendered.t()
  def telegram_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header
            level={2}
            title={dgettext("dashboard_automation_chat", "Your Telegram Integrations")}
            count={length(@integrations)}
          />
          <button phx-click="show_telegram_form" phx-target={@myself} class="btn-primary">
            {dgettext("dashboard_automation_chat", "Add Telegram Account")}
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <TelegramCard.telegram_card
              time_format={@time_format}
              integration={integration}
              testing={@telegram_testing == integration.id}
              target={@myself}
              on_edit={
                JS.push("show_edit_telegram_form", value: %{"id" => integration.id}, target: @myself)
              }
              on_delete={
                JS.push("show_telegram_delete_modal",
                  value: %{"id" => integration.id},
                  target: @myself
                )
              }
              on_toggle="toggle_telegram"
              on_test={JS.push("test_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_view_deliveries={
                JS.push("show_telegram_deliveries", value: %{"id" => integration.id}, target: @myself)
              }
              on_reenable={
                JS.push("reenable_telegram", value: %{"id" => integration.id}, target: @myself)
              }
              on_disconnect={
                JS.push("disconnect_telegram", value: %{"id" => integration.id}, target: @myself)
              }
              on_reconnect={
                if integration.bot_mode == "shared" do
                  JS.push("reconnect_telegram", value: %{"id" => integration.id}, target: @myself)
                end
              }
            />
          <% end %>
        </div>
      </div>
    <% else %>
      <TelegramEmptyState.telegram_empty_state on_create={
        JS.push("show_telegram_form", target: @myself)
      } />
    <% end %>
    """
  end
end
