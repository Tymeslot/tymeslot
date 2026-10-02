defmodule TymeslotWeb.Dashboard.Automation.WebhookCard do
  @moduledoc """
  UI component for displaying a single webhook card.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Webhooks.DeliveryStatus
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.Helpers

  attr :webhook, :map, required: true
  attr :time_format, :string, required: true
  attr :testing, :boolean, default: false
  attr :target, :any, required: true
  attr :on_edit, :any, required: true
  attr :on_delete, :any, required: true
  attr :on_toggle, :string, required: true
  attr :on_test, :any, required: true
  attr :on_view_deliveries, :any, required: true

  @spec webhook_card(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_card(assigns) do
    ~H"""
    <IntegrationCard.integration_card
      id={"#{@webhook.id}"}
      title={@webhook.name}
      status={status(@webhook)}
      summary={@webhook.url}
      summary_mono
      active={@webhook.is_active}
      toggle_event={@on_toggle}
      toggle_id={"webhook-toggle-#{@webhook.id}"}
      target={@target}
      tags={@webhook.events}
      notice={
        @webhook.disabled_reason &&
          dgettext("dashboard_automation", "Disabled: %{reason}", reason: @webhook.disabled_reason)
      }
      notice_tone={:danger}
    >
      <:icon><IconComponents.icon name={:webhook} class="w-6 h-6" /></:icon>
      <:last_activity :if={@webhook.last_triggered_at}>
        {dgettext("dashboard_automation", "Last triggered: %{time}",
          time: Helpers.format_datetime(@webhook.last_triggered_at, @time_format)
        )}
        <span :if={@webhook.last_status} class={["ml-1", status_color(@webhook.last_status)]}>
          ({status_label(@webhook.last_status)})
        </span>
      </:last_activity>
      <:last_activity :if={!@webhook.last_triggered_at} muted>
        {dgettext("dashboard_automation", "Never triggered")}
      </:last_activity>
      <:actions>
        <.loading_button
          variant={:secondary}
          size={:sm}
          icon="hero-bolt"
          loading={@testing}
          loading_text={dgettext("dashboard_automation", "Testing")}
          disabled={!@webhook.is_active}
          phx-click={@on_test}
          title={
            cond do
              !@webhook.is_active -> dgettext("dashboard_automation", "Enable webhook to test")
              @testing -> dgettext("dashboard_automation", "Testing...")
              true -> dgettext("dashboard_automation", "Test Connection")
            end
          }
        >
          {dgettext("dashboard_automation", "Test")}
        </.loading_button>
        <.action_button
          variant={:secondary}
          size={:sm}
          icon="hero-document-text"
          phx-click={@on_view_deliveries}
          title={dgettext("dashboard_automation", "View Delivery Logs")}
        >
          {dgettext("dashboard_automation", "Logs")}
        </.action_button>
      </:actions>
      <:end_actions>
        <.icon_button
          icon="hero-pencil-square"
          label={dgettext("dashboard_automation", "Edit Webhook")}
          phx-click={@on_edit}
        />
        <.icon_button
          icon="hero-trash"
          variant={:danger}
          label={dgettext("dashboard_automation", "Delete Webhook")}
          phx-click={@on_delete}
        />
      </:end_actions>
    </IntegrationCard.integration_card>
    """
  end

  # An auto-disabled webhook (a `disabled_reason` is recorded) is a fault to
  # fix; one the owner switched off is simply off.
  defp status(%{is_active: true}), do: {:success, dgettext("dashboard_automation", "Active")}

  defp status(%{disabled_reason: reason}) when is_binary(reason),
    do: {:danger, dgettext("dashboard_automation", "Disabled")}

  defp status(_webhook), do: {:neutral, dgettext("dashboard_automation", "Disabled")}

  defp status_color(last_status) do
    case DeliveryStatus.state(last_status) do
      :success -> "text-green-600 font-bold"
      :failed -> "text-red-600 font-bold"
      :unknown -> "text-tymeslot-600 font-medium"
    end
  end

  # The raw reason (e.g. "HTTP 500", "connection refused") is machine
  # diagnostic text, not UI copy, so only the state word is translated; the
  # reason is interpolated untranslated, same as the disabled-reason badge.
  defp status_label(last_status) do
    case DeliveryStatus.state(last_status) do
      :success ->
        dgettext("dashboard_automation", "Succeeded")

      :failed ->
        case DeliveryStatus.reason(last_status) do
          nil -> dgettext("dashboard_automation", "Failed")
          reason -> dgettext("dashboard_automation", "Failed: %{reason}", reason: reason)
        end

      :unknown ->
        last_status
    end
  end
end
