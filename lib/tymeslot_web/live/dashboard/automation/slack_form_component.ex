defmodule TymeslotWeb.Dashboard.Automation.SlackFormComponent do
  @moduledoc """
  Form component for creating and editing Slack integrations.

  Three render branches, keyed off `@mode`:

    * `:oauth_pending` — channel picker for a freshly-installed OAuth stub
    * `:oauth_existing` — full edit form for an active OAuth integration
    * `:webhook_url` — name + Incoming Webhook URL + optional channel hint
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Slack
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:available_events, Slack.available_events())
     |> assign(:channels, [])
     |> assign(:channels_loading?, false)
     |> assign(:channels_error, nil)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    mode = assigns[:mode] || :webhook_url
    integration = assigns[:integration]
    form_values = resolve_form_values(assigns, integration, mode)

    socket =
      socket
      |> assign(assigns)
      |> assign(:mode, mode)
      |> assign(:integration, integration)
      |> assign(:form_values, form_values)
      |> assign(:form_errors, assigns[:form_errors] || %{})
      |> maybe_start_channel_load(mode, integration)

    {:ok, socket}
  end

  defp resolve_form_values(%{form_values: %{} = values}, _integration, _mode)
       when map_size(values) > 0,
       do: values

  defp resolve_form_values(_assigns, %{} = integration, :oauth_pending) do
    %{
      "name" => integration.name || "",
      "events" => integration.events || Slack.default_events_for_new_integration(),
      "channel_id" => "",
      "channel_name" => ""
    }
  end

  defp resolve_form_values(_assigns, %{} = integration, :oauth_existing) do
    %{
      "name" => integration.name,
      "events" => integration.events,
      "channel_id" => integration.channel_id || "",
      "channel_name" => integration.channel_name || ""
    }
  end

  defp resolve_form_values(_assigns, %{} = integration, :webhook_url) do
    %{
      "name" => integration.name,
      "events" => integration.events,
      "webhook_url" => "",
      "webhook_channel_hint" => integration.webhook_channel_hint || ""
    }
  end

  defp resolve_form_values(_assigns, %{} = integration, :webhook_url_existing) do
    %{
      "name" => integration.name,
      "events" => integration.events,
      "webhook_url" => SlackIntegrationSchema.webhook_url(integration) || "",
      "webhook_channel_hint" => integration.webhook_channel_hint || ""
    }
  end

  defp resolve_form_values(_assigns, _integration, _mode) do
    %{
      "name" => "",
      "events" => Slack.default_events_for_new_integration(),
      "webhook_url" => "",
      "webhook_channel_hint" => ""
    }
  end

  @impl Phoenix.LiveComponent
  def handle_event("slack_refresh_channels", _params, socket) do
    case socket.assigns[:integration] do
      %{} = integration -> {:noreply, reload_channels(socket, integration)}
      _other -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_async(:load_channels, {:ok, {:ok, channels}}, socket) do
    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:channels_loading?, false)
     |> assign(:channels_error, nil)}
  end

  def handle_async(:load_channels, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:channels_loading?, false)
     |> assign(:channels_error, Slack.translate_error(reason))}
  end

  def handle_async(:load_channels, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:channels_loading?, false)
     |> assign(:channels_error, "Could not load Slack channels. Try again.")}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :can_submit, can_submit?(assigns))

    ~H"""
    <div class="space-y-8 pb-20">
      <%!-- Toolbar --%>
      <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
        <.section_header icon={:automation} title={form_title(@mode)} class="mb-0" />

        <button
          phx-click="slack_close_form"
          phx-target={@parent_component}
          class="flex items-center gap-2 px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
          Close
        </button>
      </div>

      <form
        id="slack-form"
        phx-change="slack_validate"
        phx-submit={submit_event(@mode)}
        phx-target={@parent_component}
        class="space-y-8"
      >
        <%!-- Details --%>
        <div class="card-glass">
          <div class="mb-6">
            <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Integration Details</h3>
            <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
              <%= details_subtitle(@mode) %>
            </p>
          </div>

          <div class="space-y-6">
            <%= if @mode != :oauth_pending do %>
              <.input
                name="slack[name]"
                label="Integration Name"
                value={Map.get(@form_values, "name", "")}
                phx-blur={JS.push("slack_validate_field", value: %{"field" => "name"}, target: @parent_component)}
                placeholder="Acme Slack Notifications"
                required
                errors={FormValidationHelpers.field_errors(@form_errors, :name)}
                icon="hero-tag"
              >
                <:description>
                  A label shown in your dashboard. Useful if you connect more than one Slack workspace.
                </:description>
              </.input>
            <% end %>

            <%= cond do %>
              <% @mode in [:webhook_url, :webhook_url_existing] -> %>
                <.input
                  name="slack[webhook_url]"
                  type="password"
                  label="Slack Webhook URL"
                  value={Map.get(@form_values, "webhook_url", "")}
                  phx-blur={JS.push("slack_validate_field", value: %{"field" => "webhook_url"}, target: @parent_component)}
                  placeholder="https://hooks.slack.com/services/T.../B.../..."
                  required
                  errors={FormValidationHelpers.field_errors(@form_errors, :webhook_url)}
                  icon="hero-link"
                >
                  <:description>
                    Tymeslot posts notifications to this URL. The destination channel is fixed by Slack when the webhook is created — see the full setup guide on
                    <a
                      href="https://tymeslot.app/docs/slack"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="font-black text-turquoise-700 hover:text-turquoise-900 underline"
                    >tymeslot.app/docs/slack</a>.
                  </:description>
                </.input>

                <.input
                  name="slack[webhook_channel_hint]"
                  label="Channel hint (optional)"
                  value={Map.get(@form_values, "webhook_channel_hint", "")}
                  phx-blur={JS.push("slack_validate_field", value: %{"field" => "webhook_channel_hint"}, target: @parent_component)}
                  placeholder="#bookings"
                  errors={FormValidationHelpers.field_errors(@form_errors, :webhook_channel_hint)}
                  icon="hero-hashtag"
                >
                  <:description>
                    Display-only label shown in your dashboard. It does not change where messages are delivered — that is set by the webhook URL itself.
                  </:description>
                </.input>

              <% @mode in [:oauth_pending, :oauth_existing] -> %>
                <.channel_picker
                  form_values={@form_values}
                  form_errors={@form_errors}
                  channels={@channels}
                  loading?={@channels_loading?}
                  error={@channels_error}
                  target={@myself}
                />
            <% end %>
          </div>
        </div>

        <%!-- Events --%>
        <div class="card-glass">
          <div class="mb-6">
            <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">Event Subscriptions</h3>
            <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
              Select which events should trigger Slack notifications.
            </p>
          </div>

          <div class="space-y-3">
            <%= for event <- @available_events do %>
              <label class="flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors">
                <.input
                  type="checkbox"
                  name="slack[events][]"
                  value={event.value}
                  checked={event.value in Map.get(@form_values, "events", [])}
                  phx-click={JS.push("slack_toggle_event", value: %{"event" => event.value}, target: @parent_component)}
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

        <%!-- Form Actions --%>
        <div class="flex justify-end gap-3 pt-4">
          <CoreComponents.action_button
            variant={:secondary}
            phx-click="slack_close_form"
            phx-target={@parent_component}
          >
            Cancel
          </CoreComponents.action_button>
          <CoreComponents.loading_button
            type="submit"
            variant={:primary}
            loading={@saving}
            loading_text="Saving..."
            disabled={!@can_submit}
            class={if !@can_submit, do: "opacity-50 cursor-not-allowed grayscale", else: ""}
          >
            <%= submit_label(@mode) %>
          </CoreComponents.loading_button>
        </div>
      </form>
    </div>
    """
  end

  attr :form_values, :map, required: true
  attr :form_errors, :map, required: true
  attr :channels, :list, required: true
  attr :loading?, :boolean, required: true
  attr :error, :any, required: true
  attr :target, :any, required: true

  defp channel_picker(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <label class="block text-token-sm font-black text-tymeslot-900">
          Channel <span class="text-red-500">*</span>
        </label>
        <button
          type="button"
          phx-click="slack_refresh_channels"
          phx-target={@target}
          disabled={@loading?}
          class="flex items-center gap-1.5 px-3 py-1.5 text-token-xs font-bold text-tymeslot-600 bg-tymeslot-50 rounded-token-lg border-2 border-tymeslot-100 hover:bg-tymeslot-100 hover:text-tymeslot-700 transition-all disabled:opacity-50 disabled:cursor-not-allowed"
          title="Refresh channel list from Slack"
        >
          <.icon
            name="hero-arrow-path"
            class={"w-3.5 h-3.5" <> if(@loading?, do: " animate-spin", else: "")}
          />
          Refresh
        </button>
      </div>

      <p class="text-token-xs text-tymeslot-500 font-medium mb-2 ml-1">
        Tymeslot will post booking notifications to this channel. Public channels appear automatically; for a private channel, invite the Tymeslot bot in Slack (<code class="px-1 py-0.5 rounded bg-tymeslot-100 text-tymeslot-700">/invite @Tymeslot</code>), then click Refresh.
      </p>

      <%= cond do %>
        <% @loading? -> %>
          <div class="flex items-center gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50">
            <svg class="w-5 h-5 animate-spin text-turquoise-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
            </svg>
            <span class="text-token-sm text-tymeslot-600 font-medium">Loading channels from Slack...</span>
          </div>

        <% is_binary(@error) -> %>
          <div class="p-4 rounded-token-xl border-2 border-red-200 bg-red-50 text-token-sm text-red-700 font-medium">
            <%= @error %>
          </div>

        <% @channels == [] -> %>
          <div class="p-4 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50 text-token-sm text-tymeslot-600 font-medium">
            No channels available. Invite the Tymeslot bot to at least one channel in Slack, then click Refresh.
          </div>

        <% true -> %>
          <select
            name="slack[channel_id]"
            class={[
              "glass-dropdown",
              FormValidationHelpers.field_errors(@form_errors, :channel_id) != [] && "input-error"
            ]}
          >
            <option value="">Pick a channel...</option>
            <%= for c <- @channels do %>
              <option value={c.id} selected={c.id == Map.get(@form_values, "channel_id")}>
                #<%= c.name %><%= if c.is_private, do: " (private)" %>
              </option>
            <% end %>
          </select>

          <%= for error <- FormValidationHelpers.field_errors(@form_errors, :channel_id) do %>
            <p class="mt-2 text-token-sm font-semibold text-red-600">{error}</p>
          <% end %>

          <%!-- Hidden channel_name pairs with the chosen channel_id; submit handler resolves it via the channels list. --%>
          <input type="hidden" name="slack[channel_name]" value={lookup_channel_name(@channels, Map.get(@form_values, "channel_id"))} />
      <% end %>
    </div>
    """
  end

  defp lookup_channel_name(channels, channel_id)
       when is_binary(channel_id) and channel_id != "" do
    case Enum.find(channels, &(&1.id == channel_id)) do
      nil -> ""
      %{name: name} -> name
    end
  end

  defp lookup_channel_name(_channels, _id), do: ""

  defp form_title(:oauth_pending), do: "Finish Slack setup"
  defp form_title(:oauth_existing), do: "Edit Slack Integration"
  defp form_title(:webhook_url), do: "Add Slack via Webhook URL"
  defp form_title(:webhook_url_existing), do: "Edit Slack Integration"

  defp details_subtitle(:oauth_pending),
    do: "Pick a channel for Tymeslot to post booking notifications to."

  defp details_subtitle(:oauth_existing),
    do: "Update the channel and event subscriptions for this Slack workspace."

  defp details_subtitle(:webhook_url),
    do: "Paste the Incoming Webhook URL Slack generated for your channel."

  defp details_subtitle(:webhook_url_existing),
    do: "Update the webhook URL or event subscriptions for this Slack integration."

  defp submit_event(:oauth_pending), do: "slack_save_channel"
  defp submit_event(:oauth_existing), do: "slack_update"
  defp submit_event(:webhook_url), do: "slack_save_webhook"
  defp submit_event(:webhook_url_existing), do: "slack_update"

  defp submit_label(:oauth_pending), do: "Save channel"
  defp submit_label(:oauth_existing), do: "Update"
  defp submit_label(:webhook_url), do: "Save"
  defp submit_label(:webhook_url_existing), do: "Update"

  defp can_submit?(assigns) do
    values = assigns.form_values
    errors = assigns.form_errors
    mode = assigns.mode

    base = present?(values, "events") and Enum.empty?(errors)

    case mode do
      :oauth_pending ->
        base and present?(values, "channel_id")

      :oauth_existing ->
        base and present?(values, "name") and present?(values, "channel_id")

      mode when mode in [:webhook_url, :webhook_url_existing] ->
        base and present?(values, "name") and present?(values, "webhook_url")
    end
  end

  defp present?(values, "events"), do: Map.get(values, "events", []) != []

  defp present?(values, key),
    do: String.trim(Map.get(values, key, "") || "") != ""

  defp maybe_start_channel_load(socket, mode, integration)
       when mode in [:oauth_pending, :oauth_existing] and not is_nil(integration) do
    # Only fire the async load on the first update for this integration to
    # avoid re-fetching channels on every parent re-render. A manual refresh
    # goes through `reload_channels/2`, which clears `:channels_loaded_for`.
    if socket.assigns[:channels_loaded_for] == integration.id do
      socket
    else
      reload_channels(socket, integration)
    end
  end

  defp maybe_start_channel_load(socket, _mode, _integration), do: socket

  # Cancels any in-flight load (later-wins guard) and fires a fresh async
  # request for the integration's channels. Shared by initial mount and the
  # manual refresh button.
  defp reload_channels(socket, integration) do
    socket
    |> cancel_async(:load_channels)
    |> assign(:channels_loading?, true)
    |> assign(:channels_error, nil)
    |> assign(:channels_loaded_for, integration.id)
    |> start_async(:load_channels, fn -> Slack.list_channels(integration) end)
  end
end
