defmodule TymeslotWeb.Dashboard.AutomationSettingsComponent do
  @moduledoc """
  LiveComponent for managing automation in the dashboard.
  Supports webhooks, Telegram, and Slack integrations.

  Event handling is delegated to focused handler modules:
    - `WebhookEventHandlers` — all webhook CRUD and operational events
    - `TelegramEventHandlers` — all Telegram CRUD and operational events
    - `SlackEventHandlers` — all Slack CRUD and operational events
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Dashboard.Automation.Modals
  alias TymeslotWeb.Dashboard.Automation.Slack.FormHandlers, as: SlackFormHandlers
  alias TymeslotWeb.Dashboard.Automation.SlackCard
  alias TymeslotWeb.Dashboard.Automation.SlackEmptyState
  alias TymeslotWeb.Dashboard.Automation.SlackEventHandlers
  alias TymeslotWeb.Dashboard.Automation.SlackFormComponent
  alias TymeslotWeb.Dashboard.Automation.TelegramCard
  alias TymeslotWeb.Dashboard.Automation.TelegramEmptyState
  alias TymeslotWeb.Dashboard.Automation.TelegramEventHandlers
  alias TymeslotWeb.Dashboard.Automation.TelegramFormComponent
  alias TymeslotWeb.Dashboard.Automation.WebhookCard
  alias TymeslotWeb.Dashboard.Automation.WebhookDocumentation
  alias TymeslotWeb.Dashboard.Automation.WebhookEmptyState
  alias TymeslotWeb.Dashboard.Automation.WebhookEventHandlers
  alias TymeslotWeb.Dashboard.Automation.WebhookFormComponent

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    modal_configs = [
      {:delete, false},
      {:deliveries, false},
      {:regenerate_token, false},
      {:telegram_delete, false},
      {:telegram_deliveries, false},
      {:slack_delete, false},
      {:slack_deliveries, false}
    ]

    telegram_enabled = Telegram.telegram_enabled?()
    slack_enabled = Slack.slack_enabled?()

    {:ok,
     socket
     |> ModalHook.mount_modal(modal_configs)
     |> assign(:active_tab, :webhooks)
     |> assign(:telegram_enabled, telegram_enabled)
     |> assign(:slack_enabled, slack_enabled)
     |> assign(:slack_oauth_mode_available?, Slack.oauth_mode_available?())
     |> assign_webhook_defaults()
     |> assign_telegram_defaults()
     |> assign_slack_defaults()}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(%{telegram_linked_integration_id: integration_id}, socket) do
    {:ok, TelegramEventHandlers.handle_linked(socket, integration_id)}
  end

  def update(%{telegram_link_expired_id: integration_id}, socket) do
    {:ok, TelegramEventHandlers.handle_link_expired(socket, integration_id)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> AutomationHelpers.load_webhooks()
      |> AutomationHelpers.maybe_load_telegram()
      |> AutomationHelpers.maybe_load_slack()
      |> maybe_subscribe_telegram()
      |> maybe_open_slack_pending_form()

    {:ok, socket}
  end

  # ============================================================================
  # Tab Switching
  # ============================================================================

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # ============================================================================
  # Webhook Events
  # ============================================================================

  def handle_event("show_webhook_form", params, socket),
    do: WebhookEventHandlers.handle_show_form(params, socket)

  def handle_event("close_webhook_form", params, socket),
    do: WebhookEventHandlers.handle_close_form(params, socket)

  def handle_event("validate_field", params, socket),
    do: WebhookEventHandlers.handle_validate_field(params, socket)

  def handle_event("toggle_event", params, socket),
    do: WebhookEventHandlers.handle_toggle_event(params, socket)

  def handle_event("create_webhook", params, socket),
    do: WebhookEventHandlers.handle_create(params, socket)

  def handle_event("show_edit_webhook_form", params, socket),
    do: WebhookEventHandlers.handle_show_edit_form(params, socket)

  def handle_event("update_webhook", params, socket),
    do: WebhookEventHandlers.handle_update(params, socket)

  def handle_event("show_delete_modal", params, socket),
    do: WebhookEventHandlers.handle_show_delete_modal(params, socket)

  def handle_event("hide_delete_modal", params, socket),
    do: WebhookEventHandlers.handle_hide_delete_modal(params, socket)

  def handle_event("delete_webhook", params, socket),
    do: WebhookEventHandlers.handle_delete(params, socket)

  def handle_event("toggle_webhook", params, socket),
    do: WebhookEventHandlers.handle_toggle(params, socket)

  def handle_event("test_connection", params, socket),
    do: WebhookEventHandlers.handle_test_connection(params, socket)

  def handle_event("show_deliveries", params, socket),
    do: WebhookEventHandlers.handle_show_deliveries(params, socket)

  def handle_event("show_regenerate_token_modal", params, socket),
    do: WebhookEventHandlers.handle_show_regenerate_token_modal(params, socket)

  def handle_event("hide_regenerate_token_modal", params, socket),
    do: WebhookEventHandlers.handle_hide_regenerate_token_modal(params, socket)

  def handle_event("regenerate_token", params, socket),
    do: WebhookEventHandlers.handle_regenerate_token(params, socket)

  def handle_event("hide_deliveries", params, socket),
    do: WebhookEventHandlers.handle_hide_deliveries(params, socket)

  # ============================================================================
  # Telegram Events
  # ============================================================================

  def handle_event("show_telegram_form", params, socket),
    do: TelegramEventHandlers.handle_show_form(params, socket)

  def handle_event("close_telegram_form", params, socket),
    do: TelegramEventHandlers.handle_close_form(params, socket)

  def handle_event("refresh_telegram_link", params, socket),
    do: TelegramEventHandlers.handle_refresh_link(params, socket)

  def handle_event("validate_telegram_field", params, socket),
    do: TelegramEventHandlers.handle_validate_field(params, socket)

  def handle_event("toggle_telegram_event", params, socket),
    do: TelegramEventHandlers.handle_toggle_event(params, socket)

  def handle_event("create_telegram", params, socket),
    do: TelegramEventHandlers.handle_create(params, socket)

  def handle_event("update_telegram", params, socket),
    do: TelegramEventHandlers.handle_update(params, socket)

  def handle_event("show_edit_telegram_form", params, socket),
    do: TelegramEventHandlers.handle_show_edit_form(params, socket)

  def handle_event("toggle_telegram", params, socket),
    do: TelegramEventHandlers.handle_toggle(params, socket)

  def handle_event("test_telegram", params, socket),
    do: TelegramEventHandlers.handle_test(params, socket)

  def handle_event("reenable_telegram", params, socket),
    do: TelegramEventHandlers.handle_reenable(params, socket)

  def handle_event("disconnect_telegram", params, socket),
    do: TelegramEventHandlers.handle_disconnect(params, socket)

  def handle_event("reconnect_telegram", params, socket),
    do: TelegramEventHandlers.handle_reconnect(params, socket)

  def handle_event("show_telegram_delete_modal", params, socket),
    do: TelegramEventHandlers.handle_show_delete_modal(params, socket)

  def handle_event("hide_telegram_delete_modal", params, socket),
    do: TelegramEventHandlers.handle_hide_delete_modal(params, socket)

  def handle_event("delete_telegram", params, socket),
    do: TelegramEventHandlers.handle_delete(params, socket)

  def handle_event("show_telegram_deliveries", params, socket),
    do: TelegramEventHandlers.handle_show_deliveries(params, socket)

  def handle_event("hide_telegram_deliveries", params, socket),
    do: TelegramEventHandlers.handle_hide_deliveries(params, socket)

  # ============================================================================
  # Slack Events — delegated to SlackEventHandlers.handle/3 by event name
  # ============================================================================

  def handle_event("slack_" <> _suffix = event, params, socket),
    do: SlackEventHandlers.handle(event, params, socket)

  # ============================================================================
  # Render
  # ============================================================================

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Modals (outside space-y layout to avoid affecting headline position) --%>
      <Modals.delete_webhook_modal
        show={@show_delete_modal}
        on_cancel={JS.push("hide_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_webhook", target: @myself)}
      />

      <%= if @show_deliveries_modal do %>
        <Modals.deliveries_modal
          show={@show_deliveries_modal}
          webhook={@selected_webhook}
          deliveries={@deliveries}
          stats={@delivery_stats}
          on_close={JS.push("hide_deliveries", target: @myself)}
        />
      <% end %>

      <Modals.regenerate_token_modal
        show={@show_regenerate_token_modal}
        on_cancel={JS.push("hide_regenerate_token_modal", target: @myself)}
        on_confirm={JS.push("regenerate_token", target: @myself)}
      />

      <%!-- Telegram Delete Modal --%>
      <Modals.delete_telegram_modal
        show={@show_telegram_delete_modal}
        on_cancel={JS.push("hide_telegram_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_telegram", target: @myself)}
      />

      <%!-- Telegram Deliveries Modal --%>
      <%= if @show_telegram_deliveries_modal && @selected_telegram do %>
        <Modals.telegram_deliveries_modal
          id="telegram-deliveries-modal"
          show={@show_telegram_deliveries_modal}
          integration={@selected_telegram}
          deliveries={@telegram_deliveries}
          stats={@telegram_delivery_stats}
          on_close={JS.push("hide_telegram_deliveries", target: @myself)}
        />
      <% end %>

      <%!-- Slack Delete Modal --%>
      <Modals.delete_slack_modal
        show={@show_slack_delete_modal}
        on_cancel={JS.push("slack_hide_delete", target: @myself)}
        on_confirm={JS.push("slack_delete", target: @myself)}
      />

      <%!-- Slack Deliveries Modal --%>
      <%= if @show_slack_deliveries_modal && @selected_slack do %>
        <Modals.slack_deliveries_modal
          id="slack-deliveries-modal"
          show={@show_slack_deliveries_modal}
          integration={@selected_slack}
          deliveries={@slack_deliveries}
          stats={@slack_delivery_stats}
          on_close={JS.push("slack_hide_deliveries", target: @myself)}
        />
      <% end %>

      <div class="space-y-10 pb-20">
      <%= cond do %>
        <% @show_webhook_form -> %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={WebhookFormComponent}
            id={"webhook-form-#{@webhook_form_mode}-#{@webhook_form_timestamp}"}
            mode={@webhook_form_mode}
            webhook={@webhook_form_data}
            form_values={@form_values}
            form_errors={@form_errors}
            saving={@saving}
            parent_component={@myself}
          />
        </div>
        <% @show_telegram_form -> %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={TelegramFormComponent}
            id={"telegram-form-#{@telegram_form_mode}-#{@telegram_form_timestamp}"}
            mode={@telegram_form_mode}
            integration={@telegram_form_data}
            form_values={@telegram_form_values}
            form_errors={@telegram_form_errors}
            saving={@telegram_saving}
            current_user={@current_user}
            parent_component={@myself}
            wizard_step={@telegram_wizard_step}
            link_expired={@telegram_link_expired}
            deep_link={@telegram_deep_link}
          />
        </div>
        <% @show_slack_form -> %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={SlackFormComponent}
            id={"slack-form-#{@slack_form_mode}-#{@slack_form_timestamp}"}
            mode={@slack_form_mode}
            integration={@slack_form_data}
            form_values={@slack_form_values}
            form_errors={@slack_form_errors}
            saving={@slack_saving}
            current_user={@current_user}
            parent_component={@myself}
          />
        </div>
        <% true -> %>
        <.section_header icon={:webhook} title="Automation" />

        <%!-- Tabs Navigation --%>
        <div class="flex flex-wrap gap-4 bg-tymeslot-50/50 p-2 rounded-[2rem] border-2 border-tymeslot-50 mb-10">
          <button
            phx-click={JS.push("switch_tab", value: %{"tab" => "webhooks"}, target: @myself)}
            class={tab_class(@active_tab == :webhooks)}
          >
            <IconComponents.icon name={:webhook} class="w-5 h-5" />
            <span>Webhooks</span>
          </button>

          <%= if @telegram_enabled do %>
            <button
              phx-click={JS.push("switch_tab", value: %{"tab" => "telegram"}, target: @myself)}
              class={tab_class(@active_tab == :telegram)}
            >
              <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
              </svg>
              <span>Telegram</span>
            </button>
          <% else %>
            <div class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 opacity-60 cursor-not-allowed">
              <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
              </svg>
              <span>Telegram</span>
              <span class="ml-2 text-token-2xs bg-tymeslot-100 px-2 py-0.5 rounded-full uppercase tracking-tighter">Disabled</span>
            </div>
          <% end %>

          <%= if @slack_enabled do %>
            <button
              phx-click={JS.push("switch_tab", value: %{"tab" => "slack"}, target: @myself)}
              class={tab_class(@active_tab == :slack)}
            >
              <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z" />
              </svg>
              <span>Slack</span>
            </button>
          <% end %>
        </div>

        <%!-- Tab Content --%>
        <div class="space-y-12">
          <%= case @active_tab do %>
            <% :webhooks -> %>
              <.webhook_tab_content
                webhooks={@webhooks}
                testing_connection={@testing_connection}
                myself={@myself}
              />
            <% :telegram -> %>
              <.telegram_tab_content
                integrations={@telegram_integrations}
                telegram_testing={@telegram_testing}
                myself={@myself}
              />
            <% :slack -> %>
              <.slack_tab_content
                integrations={@slack_integrations}
                slack_testing={@slack_testing}
                oauth_mode_available?={@slack_oauth_mode_available?}
                myself={@myself}
              />
          <% end %>
        </div>
      <% end %>
      </div>
    </div>
    """
  end

  defp webhook_tab_content(assigns) do
    ~H"""
    <%= if @webhooks != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header level={2} title="Your Webhooks" count={length(@webhooks)} />
          <button phx-click="show_webhook_form" phx-target={@myself} class="btn-primary">
            Create Webhook
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for webhook <- @webhooks do %>
            <WebhookCard.webhook_card
              webhook={webhook}
              testing={@testing_connection == webhook.id}
              target={@myself}
              on_edit={JS.push("show_edit_webhook_form", value: %{"id" => webhook.id}, target: @myself)}
              on_delete={JS.push("show_delete_modal", value: %{"id" => webhook.id}, target: @myself)}
              on_toggle="toggle_webhook"
              on_test={JS.push("test_connection", value: %{"id" => webhook.id}, target: @myself)}
              on_view_deliveries={JS.push("show_deliveries", value: %{"id" => webhook.id}, target: @myself)}
            />
          <% end %>
        </div>
      </div>
    <% else %>
      <WebhookEmptyState.webhook_empty_state on_create={JS.push("show_webhook_form", target: @myself)} />
    <% end %>

    <WebhookDocumentation.webhook_documentation />
    """
  end

  defp telegram_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header level={2} title="Your Telegram Integrations" count={length(@integrations)} />
          <button phx-click="show_telegram_form" phx-target={@myself} class="btn-primary">
            Add Telegram Account
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <TelegramCard.telegram_card
              integration={integration}
              testing={@telegram_testing == integration.id}
              target={@myself}
              on_edit={JS.push("show_edit_telegram_form", value: %{"id" => integration.id}, target: @myself)}
              on_delete={JS.push("show_telegram_delete_modal", value: %{"id" => integration.id}, target: @myself)}
              on_toggle="toggle_telegram"
              on_test={JS.push("test_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_view_deliveries={JS.push("show_telegram_deliveries", value: %{"id" => integration.id}, target: @myself)}
              on_reenable={JS.push("reenable_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_disconnect={JS.push("disconnect_telegram", value: %{"id" => integration.id}, target: @myself)}
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
      <TelegramEmptyState.telegram_empty_state on_create={JS.push("show_telegram_form", target: @myself)} />
    <% end %>
    """
  end

  attr :integrations, :list, required: true
  attr :slack_testing, :any, required: true
  attr :oauth_mode_available?, :boolean, required: true
  attr :myself, :any, required: true

  defp slack_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header level={2} title="Your Slack Integrations" count={length(@integrations)} />
          <div class="flex items-center gap-3">
            <%= if @oauth_mode_available? do %>
              <.link href={~p"/api/slack/oauth/start"} class="btn-primary">Add to Slack</.link>
            <% end %>
            <button
              phx-click="slack_show_webhook_form"
              phx-target={@myself}
              class="inline-flex items-center gap-2 px-5 py-2.5 rounded-token-xl border-2 bg-white border-tymeslot-200 text-tymeslot-700 hover:border-turquoise-200 hover:bg-turquoise-50 font-bold transition-all"
            >
              Add via webhook URL
            </button>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <SlackCard.slack_card
              integration={integration}
              testing={@slack_testing == integration.id}
              target={@myself}
              on_edit={JS.push("slack_show_edit_form", value: %{"id" => integration.id}, target: @myself)}
              on_delete={JS.push("slack_confirm_delete", value: %{"id" => integration.id}, target: @myself)}
              on_toggle="slack_toggle_active"
              on_test={JS.push("slack_test", value: %{"id" => integration.id}, target: @myself)}
              on_view_deliveries={JS.push("slack_show_deliveries", value: %{"id" => integration.id}, target: @myself)}
              on_reenable={JS.push("slack_reenable", value: %{"id" => integration.id}, target: @myself)}
              on_pick_channel={JS.push("slack_show_channel_picker", value: %{"id" => integration.id}, target: @myself)}
              on_disconnect={JS.push("slack_disconnect", value: %{"id" => integration.id}, target: @myself)}
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp assign_webhook_defaults(socket) do
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

  defp assign_telegram_defaults(socket) do
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

  defp assign_slack_defaults(socket) do
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

  defp tab_class(true) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02] cursor-default"
  end

  defp tab_class(false) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 hover:text-tymeslot-600 hover:bg-white/50 cursor-pointer"
  end

  defp maybe_subscribe_telegram(%{assigns: %{telegram_subscribed: true}} = socket), do: socket

  defp maybe_subscribe_telegram(socket) do
    if socket.assigns.telegram_enabled and connected?(socket) do
      user_id = socket.assigns.current_user.id
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "telegram_link:#{user_id}")
      assign(socket, :telegram_subscribed, true)
    else
      socket
    end
  end

  # If the page arrived with `?slack_pending=<id>` from the OAuth callback,
  # immediately surface the channel-picker form for that integration once per
  # navigation. Tracked via `:slack_pending_opened_for` so re-renders don't
  # re-open the form after the user closes it.
  defp maybe_open_slack_pending_form(socket) do
    with true <- Map.get(socket.assigns, :slack_enabled, false),
         %{} = params <- socket.assigns[:params],
         pending_id when is_binary(pending_id) <- params["slack_pending"],
         {parsed_id, _rest} when is_integer(parsed_id) <- Integer.parse(pending_id),
         true <- socket.assigns[:slack_pending_opened_for] != parsed_id,
         {:ok, integration} <- AutomationHelpers.get_slack_for_user(socket, parsed_id) do
      socket
      |> assign(:active_tab, :slack)
      |> assign(:slack_pending_opened_for, parsed_id)
      |> SlackFormHandlers.open_oauth_form(integration)
    else
      _other -> socket
    end
  end
end
