defmodule TymeslotWeb.Dashboard.AutomationSettingsComponent do
  @moduledoc """
  LiveComponent for managing automation in the dashboard.
  Supports webhooks, Telegram, and Slack integrations.

  Event handling is delegated to focused handler modules:
    - `WebhookEventHandlers` — all webhook CRUD and operational events
    - `TelegramEventHandlers` — all Telegram CRUD and operational events
    - `SlackEventHandlers` — all Slack CRUD and operational events

  Markup is delegated to focused function-component modules:
    - `TabNav` — the tab bar
    - `WebhookTab`, `TelegramTab`, `SlackTab` — the body of each tab
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingApi
  alias Tymeslot.Profiles
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias TymeslotWeb.Dashboard.Automation.Defaults
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Dashboard.Automation.Modals
  alias TymeslotWeb.Dashboard.Automation.Slack.FormHandlers, as: SlackFormHandlers
  alias TymeslotWeb.Dashboard.Automation.SlackEventHandlers
  alias TymeslotWeb.Dashboard.Automation.SlackFormComponent
  alias TymeslotWeb.Dashboard.Automation.SlackTab
  alias TymeslotWeb.Dashboard.Automation.TabNav
  alias TymeslotWeb.Dashboard.Automation.TelegramEventHandlers
  alias TymeslotWeb.Dashboard.Automation.TelegramFormComponent
  alias TymeslotWeb.Dashboard.Automation.TelegramTab
  alias TymeslotWeb.Dashboard.Automation.WebhookEventHandlers
  alias TymeslotWeb.Dashboard.Automation.WebhookFormComponent
  alias TymeslotWeb.Dashboard.Automation.WebhookTab

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
     |> Defaults.assign_webhook_defaults()
     |> Defaults.assign_telegram_defaults()
     |> Defaults.assign_slack_defaults()}
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
      |> load_booking_api()
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
  # Booking API Events
  # ============================================================================

  def handle_event("enable_booking_api", _params, socket),
    do: {:noreply, update_booking_api(socket, &BookingApi.enable/1)}

  def handle_event("regenerate_booking_api_token", _params, socket),
    do: {:noreply, update_booking_api(socket, &BookingApi.regenerate_token/1)}

  def handle_event("disable_booking_api", _params, socket),
    do: {:noreply, update_booking_api(socket, &BookingApi.disable/1)}

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
          time_format={@time_format}
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
          time_format={@time_format}
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
          time_format={@time_format}
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
            <.section_header icon={:webhook} title={dgettext("dashboard_automation", "Automation")} />

            <%!-- Tabs Navigation --%>
            <TabNav.tab_nav
              active_tab={@active_tab}
              telegram_enabled={@telegram_enabled}
              slack_enabled={@slack_enabled}
              myself={@myself}
            />

            <%!-- Tab Content --%>
            <div class="space-y-12">
              <%= case @active_tab do %>
                <% :webhooks -> %>
                  <WebhookTab.webhook_tab_content
                    webhooks={@webhooks}
                    testing_connection={@testing_connection}
                    time_format={@time_format}
                    booking_api_token={@booking_api_token}
                    booking_api_endpoint_url={@booking_api_endpoint_url}
                    myself={@myself}
                  />
                <% :telegram -> %>
                  <TelegramTab.telegram_tab_content
                    integrations={@telegram_integrations}
                    telegram_testing={@telegram_testing}
                    time_format={@time_format}
                    myself={@myself}
                  />
                <% :slack -> %>
                  <SlackTab.slack_tab_content
                    integrations={@slack_integrations}
                    slack_testing={@slack_testing}
                    oauth_mode_available?={@slack_oauth_mode_available?}
                    time_format={@time_format}
                    myself={@myself}
                  />
              <% end %>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp load_booking_api(socket) do
    socket = assign(socket, :booking_api_endpoint_url, url(~p"/api/v1/bookings"))

    case Profiles.get_or_create_profile(socket.assigns.current_user.id) do
      {:ok, profile} ->
        socket
        |> assign(:booking_api_profile, profile)
        |> assign(:booking_api_token, profile.booking_api_token)

      _error ->
        socket
        |> assign(:booking_api_profile, nil)
        |> assign(:booking_api_token, nil)
    end
  end

  defp update_booking_api(%{assigns: %{booking_api_profile: %{} = profile}} = socket, fun) do
    case fun.(profile) do
      {:ok, _updated} -> load_booking_api(socket)
      {:error, _changeset} -> socket
    end
  end

  defp update_booking_api(socket, _fun), do: socket

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
