defmodule TymeslotWeb.Dashboard.Automation.WebhookTab do
  @moduledoc """
  Markup for the webhooks tab of `TymeslotWeb.Dashboard.AutomationSettingsComponent`.

  Rendering only: every interaction is pushed back to the owning LiveComponent
  through the `:myself` target passed in by the caller.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Automation.BookingApiSection
  alias TymeslotWeb.Dashboard.Automation.WebhookCard
  alias TymeslotWeb.Dashboard.Automation.WebhookDocumentation
  alias TymeslotWeb.Dashboard.Automation.WebhookEmptyState

  attr :webhooks, :list, required: true
  attr :time_format, :string, required: true
  attr :testing_connection, :any, required: true
  attr :booking_api_token, :string, default: nil
  attr :booking_api_endpoint_url, :string, required: true
  attr :myself, :any, required: true

  @spec webhook_tab_content(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_tab_content(assigns) do
    ~H"""
    <%= if @webhooks != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header
            level={2}
            title={dgettext("dashboard_automation", "Your Webhooks")}
            count={length(@webhooks)}
          />
          <button phx-click="show_webhook_form" phx-target={@myself} class="btn-primary">
            {dgettext("dashboard_automation", "Create Webhook")}
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for webhook <- @webhooks do %>
            <WebhookCard.webhook_card
              time_format={@time_format}
              webhook={webhook}
              testing={@testing_connection == webhook.id}
              target={@myself}
              on_edit={
                JS.push("show_edit_webhook_form", value: %{"id" => webhook.id}, target: @myself)
              }
              on_delete={JS.push("show_delete_modal", value: %{"id" => webhook.id}, target: @myself)}
              on_toggle="toggle_webhook"
              on_test={JS.push("test_connection", value: %{"id" => webhook.id}, target: @myself)}
              on_view_deliveries={
                JS.push("show_deliveries", value: %{"id" => webhook.id}, target: @myself)
              }
            />
          <% end %>
        </div>
      </div>
    <% else %>
      <WebhookEmptyState.webhook_empty_state on_create={JS.push("show_webhook_form", target: @myself)} />
    <% end %>

    <WebhookDocumentation.webhook_documentation />

    <BookingApiSection.booking_api_section
      token={@booking_api_token}
      endpoint_url={@booking_api_endpoint_url}
      myself={@myself}
    />
    """
  end
end
