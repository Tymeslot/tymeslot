defmodule TymeslotWeb.Dashboard.Automation.TelegramFormComponent do
  @moduledoc """
  Form component for creating and editing Telegram integrations.
  Renders own-bot mode form or shared-bot wizard based on feature flag.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Telegram
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:available_events, Telegram.available_events())
     |> assign(:shared_bot_mode, Telegram.shared_bot_mode?())
     |> assign(:wizard_step, 1)
     |> assign(:deep_link, nil)
     |> assign(:link_expired, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    mode = assigns[:mode] || :create
    integration = assigns[:integration]

    form_values =
      cond do
        Map.has_key?(assigns, :form_values) ->
          assigns.form_values

        mode == :edit && integration ->
          %{
            "name" => integration.name,
            "events" => integration.events
          }

        true ->
          %{"name" => "", "events" => []}
      end

    socket =
      socket
      |> assign(assigns)
      |> assign(:mode, mode)
      |> assign(:integration, integration)
      |> assign(:form_values, form_values)
      |> assign(:form_errors, assigns[:form_errors] || %{})

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :can_submit, can_submit?(assigns))

    ~H"""
    <div class="space-y-8 pb-20">
      <!-- Toolbar -->
      <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
        <.section_header
          icon={:automation}
          title={form_title(@mode, @shared_bot_mode, @wizard_step)}
          class="mb-0"
        />

        <button
          phx-click="close_telegram_form"
          phx-target={@parent_component}
          class="flex items-center gap-2 px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
          </svg>
          Close
        </button>
      </div>

      <%= if @shared_bot_mode && @mode == :create && @wizard_step == 1 do %>
        <!-- Shared Bot: Step 1 — Deep Link -->
        <.shared_bot_step1
          deep_link={@deep_link}
          link_expired={@link_expired}
          parent_component={@parent_component}
        />
      <% else %>
        <!-- Standard Form (own-bot create/edit, shared-bot step 2/edit) -->
        <form
          id="telegram-form"
          phx-submit={
            if @mode == :create do
              JS.push("create_telegram", target: @parent_component)
            else
              JS.push("update_telegram", target: @parent_component)
            end
          }
          phx-target={@parent_component}
          class="space-y-8"
        >
          <!-- Name & Details -->
          <div class="card-glass">
            <div class="mb-6">
              <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Integration Details</h3>
              <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
                Configure your Telegram notification settings.
              </p>
            </div>

            <div class="space-y-6">
              <.input
                name="telegram[name]"
                label="Integration Name"
                value={Map.get(@form_values, "name", "")}
                phx-blur={JS.push("validate_telegram_field", value: %{"field" => "name"}, target: @parent_component)}
                placeholder="My Telegram Notifications"
                required
                errors={FormValidationHelpers.field_errors(@form_errors, :name)}
                icon="hero-tag"
              />

              <%= if !@shared_bot_mode do %>
                <.input
                  name="telegram[bot_token]"
                  type="password"
                  label="Bot Token"
                  value={Map.get(@form_values, "bot_token", "")}
                  phx-blur={JS.push("validate_telegram_field", value: %{"field" => "bot_token"}, target: @parent_component)}
                  placeholder="123456789:ABCdefGHI..."
                  required
                  errors={FormValidationHelpers.field_errors(@form_errors, :bot_token)}
                  icon="hero-key"
                />

                <.input
                  name="telegram[chat_id]"
                  label="Chat ID"
                  value={Map.get(@form_values, "chat_id", "")}
                  phx-blur={JS.push("validate_telegram_field", value: %{"field" => "chat_id"}, target: @parent_component)}
                  placeholder="-1001234567890 or @channelname"
                  required
                  errors={FormValidationHelpers.field_errors(@form_errors, :chat_id)}
                  icon="hero-chat-bubble-left"
                />

                <div class="p-4 rounded-token-xl bg-turquoise-50/50 border-2 border-turquoise-100">
                  <div class="flex gap-3">
                    <div class="mt-0.5">
                      <svg class="w-5 h-5 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                      </svg>
                    </div>
                    <div>
                      <p class="text-token-sm font-black text-turquoise-900">How to get your Bot Token & Chat ID</p>
                      <p class="text-token-xs text-turquoise-700 font-medium mt-0.5">
                        Message <strong>@BotFather</strong> on Telegram to create a bot and get its token.
                        To find your Chat ID, message <strong>@userinfobot</strong> or add your bot to a group and use the Telegram API.
                      </p>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Events Selection -->
          <div class="card-glass">
            <div class="mb-6">
              <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Event Subscriptions</h3>
              <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
                Select which events should trigger Telegram notifications.
              </p>
            </div>

            <div class="space-y-3">
              <%= for event <- @available_events do %>
                <label class="flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors">
                  <.input
                    type="checkbox"
                    name="telegram[events][]"
                    value={event.value}
                    checked={event.value in Map.get(@form_values, "events", [])}
                    phx-click={JS.push("toggle_telegram_event", value: %{"event" => event.value}, target: @parent_component)}
                  />
                  <div class="flex-1">
                    <div class="font-black text-tymeslot-900"><%= event.label %></div>
                    <div class="text-token-sm text-tymeslot-600 font-medium"><%= event.description %></div>
                  </div>
                </label>
              <% end %>
            </div>
            <%= for error <- FormValidationHelpers.field_errors(@form_errors, :events) do %>
              <p class="text-token-sm text-red-600 font-medium mt-3"><%= error %></p>
            <% end %>
          </div>

          <!-- Form Actions -->
          <div class="flex justify-end gap-3 pt-4">
            <CoreComponents.action_button
              variant={:secondary}
              phx-click="close_telegram_form"
              phx-target={@parent_component}
            >
              Cancel
            </CoreComponents.action_button>
            <CoreComponents.loading_button
              type="submit"
              variant={:primary}
              loading={@saving}
              loading_text={if(!@shared_bot_mode && @mode == :create, do: "Testing & Saving...", else: "Saving...")}
              disabled={!@can_submit}
              class={if !@can_submit, do: "opacity-50 cursor-not-allowed grayscale", else: ""}
            >
              <%= cond do %>
                <% !@shared_bot_mode && @mode == :create -> %>Test & Save
                <% @mode == :create -> %>Save
                <% true -> %>Update
              <% end %>
            </CoreComponents.loading_button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  defp shared_bot_step1(assigns) do
    ~H"""
    <div class="card-glass text-center py-12">
      <div class="w-20 h-20 bg-turquoise-50 rounded-token-3xl mx-auto mb-6 flex items-center justify-center border-2 border-turquoise-100">
        <svg class="w-10 h-10 text-turquoise-600" viewBox="0 0 24 24" fill="currentColor">
          <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
        </svg>
      </div>

      <%= if @link_expired do %>
        <h3 class="text-token-2xl font-black text-amber-700 mb-3">Link Expired</h3>
        <p class="text-tymeslot-600 font-medium mb-8 max-w-md mx-auto">
          The link has expired. Click below to generate a new one.
        </p>
        <button
          phx-click="refresh_telegram_link"
          phx-target={@parent_component}
          class="btn-primary"
        >
          Generate New Link
        </button>
      <% else %>
        <h3 class="text-token-2xl font-black text-tymeslot-900 mb-3">Connect Telegram</h3>
        <p class="text-tymeslot-600 font-medium mb-8 max-w-md mx-auto">
          Click the button below to open Telegram and link your account.
          Once connected, you'll configure notification preferences.
        </p>

        <%= if @deep_link do %>
          <a
            href={@deep_link}
            target="_blank"
            rel="noopener noreferrer"
            class="btn-primary inline-flex items-center gap-2"
          >
            <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
              <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
            </svg>
            Open in Telegram
          </a>

          <div class="mt-6 flex items-center justify-center gap-2 text-token-sm text-tymeslot-500">
            <svg class="w-4 h-4 animate-pulse text-turquoise-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <span>Waiting for Telegram connection... (link expires in 10 minutes)</span>
          </div>
        <% else %>
          <div class="text-tymeslot-500 font-medium">
            Setting up connection...
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp can_submit?(assigns) do
    values = assigns.form_values
    errors = assigns.form_errors

    has_name = String.trim(Map.get(values, "name", "")) != ""
    has_events = Enum.any?(Map.get(values, "events", []))
    no_errors = Enum.empty?(errors)

    if assigns.shared_bot_mode do
      has_name && has_events && no_errors
    else
      has_bot_token = String.trim(Map.get(values, "bot_token", "")) != ""
      has_chat_id = String.trim(Map.get(values, "chat_id", "")) != ""
      has_name && has_bot_token && has_chat_id && has_events && no_errors
    end
  end

  defp form_title(:create, true, 1), do: "Connect Telegram"
  defp form_title(:create, _shared_bot, _step), do: "Add Telegram Account"
  defp form_title(:edit, _shared_bot, _step), do: "Edit Telegram Integration"
end
