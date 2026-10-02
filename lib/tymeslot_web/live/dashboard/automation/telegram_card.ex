defmodule TymeslotWeb.Dashboard.Automation.TelegramCard do
  @moduledoc false
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

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
  attr :on_disconnect, :any, default: nil
  attr :on_reconnect, :any, default: nil

  @spec telegram_card(map()) :: Phoenix.LiveView.Rendered.t()
  def telegram_card(assigns) do
    {tone, pulse, label} = status_presentation(assigns.integration.status)

    assigns =
      assign(assigns, status: assigns.integration.status, tone: tone, pulse: pulse, label: label)

    ~H"""
    <IntegrationCard.integration_card
      id={"#{@integration.id}"}
      title={@integration.name}
      status={{@tone, @label}}
      pulse={@pulse}
      summary={
        @integration.chat_id &&
          dgettext("dashboard_automation_chat", "Chat: %{chat_id}",
            chat_id: truncate_chat_id(@integration.chat_id)
          )
      }
      summary_mono
      active={@status != :paused and @status != :auto_disabled}
      toggle_event={@status in [:active, :paused] && @on_toggle}
      toggle_id={"telegram-toggle-#{@integration.id}"}
      target={@target}
      tags={@integration.events}
      notice={notice(@status, @integration)}
      notice_tone={(@status == :auto_disabled && :danger) || :warning}
    >
      <:icon><IconComponents.icon name={:telegram} class="w-6 h-6" /></:icon>
      <:last_activity :if={@status != :pending_link && @integration.last_triggered_at}>
        {dgettext("dashboard_automation_chat", "Last triggered: %{time}",
          time: AutomationHelpers.format_datetime(@integration.last_triggered_at, @time_format)
        )}
      </:last_activity>
      <:last_activity :if={@status != :pending_link && !@integration.last_triggered_at} muted>
        {dgettext("dashboard_automation_chat", "Never triggered")}
      </:last_activity>
      <:actions>
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
        <%!-- Shared bot only: the link step is ours to restart. --%>
        <.action_button
          :if={@status == :pending_link && @integration.bot_mode == "shared" && @on_reconnect}
          size={:sm}
          phx-click={@on_reconnect}
        >
          {dgettext("dashboard_automation_chat", "Connect")}
        </.action_button>
        <.action_button
          :if={@status == :auto_disabled && @on_reenable}
          size={:sm}
          phx-click={@on_reenable}
        >
          {dgettext("dashboard_automation_chat", "Re-enable")}
        </.action_button>
        <.action_button
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
          :if={@status != :pending_link}
          icon="hero-pencil-square"
          label={dgettext("dashboard_automation_chat", "Edit")}
          phx-click={@on_edit}
        />
        <%!-- Shared bot mode only, once a chat is linked. --%>
        <.icon_button
          :if={@on_disconnect && @integration.bot_mode == "shared" && @integration.chat_id}
          icon="hero-link"
          variant={:warning}
          label={dgettext("dashboard_automation_chat", "Disconnect Telegram")}
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

  defp status_presentation(:pending_link),
    do: {:warning, true, dgettext("dashboard_automation_chat", "Awaiting connection")}

  defp status_presentation(:active),
    do: {:success, false, dgettext("dashboard_automation_chat", "Connected")}

  defp status_presentation(:paused),
    do: {:neutral, false, dgettext("dashboard_automation_chat", "Paused")}

  defp status_presentation(:auto_disabled),
    do: {:danger, false, dgettext("dashboard_automation_chat", "Disabled")}

  defp notice(:pending_link, _integration),
    do:
      dgettext("dashboard_automation_chat", "Connect Telegram to start receiving notifications.")

  defp notice(:auto_disabled, integration),
    do:
      dgettext("dashboard_automation_chat", "Disabled: %{reason}",
        reason: disabled_reason_label(integration.disabled_reason)
      )

  defp notice(_status, _integration), do: nil

  defp disabled_reason_label(nil), do: dgettext("dashboard_automation_chat", "auto-disabled")
  defp disabled_reason_label(""), do: dgettext("dashboard_automation_chat", "auto-disabled")

  defp disabled_reason_label("invalid_token"),
    do: dgettext("dashboard_automation_chat", "bot token was rejected")

  defp disabled_reason_label("bot_blocked"),
    do: dgettext("dashboard_automation_chat", "bot was blocked by the user")

  defp disabled_reason_label("bot_kicked"),
    do: dgettext("dashboard_automation_chat", "bot was kicked from the group")

  defp disabled_reason_label("chat_unreachable"),
    do: dgettext("dashboard_automation_chat", "chat is no longer reachable")

  defp disabled_reason_label("too_many_failures"),
    do: dgettext("dashboard_automation_chat", "too many consecutive delivery failures")

  defp disabled_reason_label("rate_limited"),
    do: dgettext("dashboard_automation_chat", "repeatedly rate-limited by Telegram")

  defp disabled_reason_label(reason) when is_binary(reason), do: reason

  defp truncate_chat_id(chat_id) when is_binary(chat_id) do
    if String.length(chat_id) > 12 do
      String.slice(chat_id, 0, 12) <> "..."
    else
      chat_id
    end
  end
end
