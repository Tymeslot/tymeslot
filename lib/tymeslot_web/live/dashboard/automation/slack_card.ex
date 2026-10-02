defmodule TymeslotWeb.Dashboard.Automation.SlackCard do
  @moduledoc false
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Components.UI.StatusSwitch
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
    assigns = assign(assigns, :status, SlackIntegrationSchema.status(assigns.integration))

    ~H"""
    <div class={[
      "card-glass p-4 sm:p-6 transition-all duration-300 group",
      card_style(@status)
    ]}>
      <div class="flex flex-col gap-4">
        <%!-- Top row: Icon + Info + Toggle/Badge --%>
        <div class="flex items-start gap-4 sm:gap-5">
          <%!-- Slack Icon --%>
          <div class={[
            "p-3 rounded-token-2xl transition-colors duration-300 shrink-0",
            icon_bg(@status)
          ]}>
            <IconComponents.icon name={:slack} class={"w-6 h-6 #{icon_color(@status)}"} />
          </div>

          <%!-- Integration Details --%>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-3 mb-2">
              <h3 class={[
                "text-token-xl font-black tracking-tight",
                if(@status == :active, do: "text-tymeslot-900", else: "text-tymeslot-500")
              ]}>
                {@integration.name}
              </h3>
              <.status_pill status={@status} />
            </div>

            <div class="text-token-sm text-tymeslot-600 font-medium mb-3 truncate">
              {location_label(@integration)}
            </div>

            <%!-- Event Tags --%>
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for event <- @integration.events do %>
                <span class={[
                  "inline-flex items-center gap-1.5 text-xs font-bold px-2.5 py-1 rounded-token-lg border",
                  event_tag_style(@status)
                ]}>
                  <div class={["w-1.5 h-1.5 rounded-full", event_dot_style(@status)]} />
                  {event}
                </span>
              <% end %>
            </div>

            <%!-- Status-specific content --%>
            <%= if @status == :pending_oauth do %>
              <div class="text-token-sm text-amber-600 font-medium">
                {dgettext("dashboard_automation_chat", "Pick a channel to finish setup.")}
              </div>
            <% else %>
              <%= if @integration.last_triggered_at do %>
                <div class="flex items-center gap-2 text-token-sm text-tymeslot-500">
                  <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                  <span>{dgettext("dashboard_automation_chat", "Last triggered: %{time}",
                    time:
                      AutomationHelpers.format_datetime(@integration.last_triggered_at, @time_format)
                  )}</span>
                </div>
              <% else %>
                <div class="flex items-center gap-2 text-token-sm text-tymeslot-400 italic">
                  <.icon name="hero-clock" class="w-4 h-4 shrink-0" />
                  <span>{dgettext("dashboard_automation_chat", "Never triggered")}</span>
                </div>
              <% end %>

              <%= if @status == :auto_disabled do %>
                <div class="mt-2 text-token-sm text-red-600 font-medium">
                  {dgettext("dashboard_automation_chat", "Disabled: %{reason}",
                    reason: disabled_reason_label(@integration.disabled_reason)
                  )}
                </div>
              <% end %>
            <% end %>
          </div>

          <%!-- Status Toggle (active/paused only) --%>
          <div class="shrink-0 ml-2">
            <%= if @status in [:active, :paused] do %>
              <StatusSwitch.status_switch
                id={"slack-toggle-#{@integration.id}"}
                checked={@integration.is_active}
                on_change={@on_toggle}
                target={@target}
                phx_value_id={"#{@integration.id}"}
                size={:medium}
                class="ring-4 ring-tymeslot-50 group-hover:ring-turquoise-50 transition-all duration-300"
              />
            <% end %>
          </div>
        </div>

        <%!-- Bottom: Actions --%>
        <div class="flex items-center gap-2 shrink-0 border-t border-tymeslot-100 pt-3">
          <%!-- Pick a channel (pending_oauth only) --%>
          <%= if @status == :pending_oauth && @on_pick_channel do %>
            <.action_button size={:sm} phx-click={@on_pick_channel}>
              {dgettext("dashboard_automation_chat", "Pick a channel")}
            </.action_button>
          <% end %>

          <%!-- Reconnect (pending_oauth OAuth only — restart OAuth from scratch) --%>
          <%= if @status == :pending_oauth && @integration.app_mode == "oauth" && @on_reconnect do %>
            <.action_button
              variant={:secondary}
              size={:sm}
              icon="hero-arrow-path"
              phx-click={@on_reconnect}
            >
              {dgettext("dashboard_automation_chat", "Reconnect")}
            </.action_button>
          <% end %>

          <%!-- Test Button --%>
          <%= if @status in [:active, :paused] do %>
            <.loading_button
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
          <% end %>

          <%!-- Re-enable Button (auto_disabled only) --%>
          <%= if @status == :auto_disabled && @on_reenable do %>
            <.action_button size={:sm} phx-click={@on_reenable}>
              {dgettext("dashboard_automation_chat", "Re-enable")}
            </.action_button>
          <% end %>

          <%!-- Logs Button --%>
          <%= if @status != :pending_oauth do %>
            <.action_button
              variant={:secondary}
              size={:sm}
              icon="hero-document-text"
              phx-click={@on_view_deliveries}
            >
              {dgettext("dashboard_automation_chat", "Logs")}
            </.action_button>
          <% end %>

          <div class="ml-auto flex items-center gap-2">
            <%!-- Edit Button --%>
            <%= if @status != :pending_oauth do %>
              <.icon_button
                icon="hero-pencil-square"
                label={dgettext("dashboard_automation_chat", "Edit")}
                phx-click={@on_edit}
              />
            <% end %>

            <%!-- Disconnect Button (OAuth mode only, once channel is set) --%>
            <%= if @on_disconnect && @integration.app_mode == "oauth" && @integration.channel_id do %>
              <.icon_button
                icon="hero-no-symbol"
                variant={:warning}
                label={dgettext("dashboard_automation_chat", "Disconnect Slack")}
                phx-click={@on_disconnect}
              />
            <% end %>

            <%!-- Delete Button --%>
            <.icon_button
              icon="hero-trash"
              variant={:danger}
              label={dgettext("dashboard_automation_chat", "Delete")}
              phx-click={@on_delete}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    {tone, pulse, label} = status_presentation(assigns.status)
    assigns = assign(assigns, tone: tone, pulse: pulse, label: label)

    ~H"""
    <.pill tone={@tone} dot pulse={@pulse}>{@label}</.pill>
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

  defp card_style(:active), do: "hover:shadow-xl"
  defp card_style(:paused), do: "opacity-75 grayscale-[0.3] bg-tymeslot-100/50"
  defp card_style(:auto_disabled), do: "opacity-75 border-red-200 bg-red-50/30"
  defp card_style(:pending_oauth), do: "border-amber-200 bg-amber-50/30"

  defp icon_bg(:active), do: "bg-tymeslot-50 group-hover:bg-white"
  defp icon_bg(:pending_oauth), do: "bg-amber-50"
  defp icon_bg(_status), do: "bg-tymeslot-200"

  defp icon_color(:active), do: "text-turquoise-600"
  defp icon_color(:pending_oauth), do: "text-amber-600"
  defp icon_color(:auto_disabled), do: "text-red-400"
  defp icon_color(_status), do: "text-tymeslot-400"

  defp event_tag_style(:active), do: "bg-turquoise-50 text-turquoise-700 border-turquoise-200"
  defp event_tag_style(_status), do: "bg-tymeslot-100 text-tymeslot-500 border-tymeslot-200"

  defp event_dot_style(:active), do: "bg-turquoise-500"
  defp event_dot_style(_status), do: "bg-tymeslot-400"

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
