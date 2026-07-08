defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents do
  @moduledoc """
  Shared HEEx components for calendar integration configuration forms.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import TymeslotWeb.Components.CoreComponents

  attr :provider, :string, required: true
  attr :show_calendar_selection, :boolean, required: true
  attr :discovered_calendars, :list, required: true
  attr :discovery_credentials, :map, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :saving, :boolean, required: true
  attr :target, :any, required: true
  attr :myself, :any, required: true
  attr :suggested_name, :string, required: true
  attr :name_placeholder, :string, default: nil
  attr :url_placeholder, :string, default: "https://example.com/remote.php/dav"
  attr :url_locked, :boolean, default: false
  attr :url_value, :string, default: ""
  attr :url_locked_tooltip, :string, default: nil
  attr :username_placeholder, :string, default: nil
  attr :password_placeholder, :string, default: nil

  @spec config_form(map()) :: Phoenix.LiveView.Rendered.t()
  def config_form(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @show_calendar_selection do %>
        <form
          id={"calendar-integration-form-#{@provider}"}
          phx-submit="add_integration"
          phx-change="track_form_change"
          phx-target={@target}
          class="space-y-6"
        >
          <.integration_name_field
            form_errors={@form_errors}
            suggested_name={Map.get(@form_values, "name", @suggested_name)}
            placeholder={@name_placeholder || dgettext("dashboard_calendar_providers", "My Calendar")}
            target={@target}
          />

          <input type="hidden" name="integration[provider]" value={@provider} />

          <p class="text-sm text-tymeslot-500">
            {dgettext("dashboard_calendar_providers", "Select the calendars you want to sync for availability checks.")}
          </p>

          <.calendar_selection discovered_calendars={@discovered_calendars} />

          <input type="hidden" name="integration[url]" value={@discovery_credentials[:url]} />
          <input type="hidden" name="integration[username]" value={@discovery_credentials[:username]} />
          <input type="hidden" name="integration[password]" value={@discovery_credentials[:password]} />

          <%= if error = form_level_error(@form_errors) do %>
            <.error_banner error={error} />
          <% end %>

          <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
            <UIComponents.secondary_button target={@target} />
            <UIComponents.form_submit_button saving={@saving} />
          </div>
        </form>
      <% else %>
        <form
          id={"calendar-discovery-form-#{@provider}"}
          phx-submit="discover_calendars"
          phx-change="track_form_change"
          phx-target={@target}
          class="space-y-5"
        >
          <input type="hidden" name="integration[provider]" value={@provider} />

          <p class="text-sm text-tymeslot-500">
            {dgettext("dashboard_calendar_providers", "Enter your server URL and credentials to discover calendars.")}
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.integration_name_field
              form_errors={@form_errors}
              suggested_name={Map.get(@form_values, "name", @suggested_name)}
              placeholder={@name_placeholder || dgettext("dashboard_calendar_providers", "My Calendar")}
              field_name="integration[name]"
              target={@target}
            />

            <%= if @url_locked do %>
              <.locked_url_field
                value={@url_value}
                tooltip={
                  @url_locked_tooltip ||
                    dgettext(
                      "dashboard_calendar_providers",
                      "This server address is fixed for this provider"
                    )
                }
                name="integration[url]"
              />
            <% else %>
              <.text_field
                id="discovery_url"
                name="integration[url]"
                label={dgettext("dashboard_calendar_providers", "Server URL")}
                value={Map.get(@form_values, "url", "")}
                placeholder={@url_placeholder}
                errors={FormValidationHelpers.field_errors(@form_errors, :url)}
                target={@target}
                field="url"
                icon="hero-globe-alt"
              />
            <% end %>

            <.text_field
              id="discovery_username"
              name="integration[username]"
              label={dgettext("dashboard_calendar_providers", "Username")}
              value={Map.get(@form_values, "username", "")}
              placeholder={@username_placeholder || dgettext("dashboard_calendar_providers", "Username")}
              errors={FormValidationHelpers.field_errors(@form_errors, :username)}
              target={@target}
              field="username"
              icon="hero-user"
            />

            <.password_field
              id="discovery_password"
              name="integration[password]"
              label={dgettext("dashboard_calendar_providers", "Password / App Password")}
              value={Map.get(@form_values, "password", "")}
              placeholder={@password_placeholder || dgettext("dashboard_calendar_providers", "Password")}
              errors={FormValidationHelpers.field_errors(@form_errors, :password)}
              target={@target}
              field="password"
            />
          </div>

          <%= if error = form_level_error(@form_errors) do %>
            <.error_banner error={error} />
          <% end %>

          <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
            <UIComponents.secondary_button target={@target} />
            <UIComponents.form_submit_button
              saving={@saving}
              text={dgettext("dashboard_calendar_providers", "Discover calendars")}
              saving_text={dgettext("dashboard_calendar_providers", "Discovering...")}
            />
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  attr :form_errors, :map, required: true
  attr :suggested_name, :string, required: true
  attr :placeholder, :string, required: true
  attr :field_name, :string, default: "integration[name]"
  attr :target, :any, default: nil

  @spec integration_name_field(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_name_field(assigns) do
    ~H"""
    <.input
      id="integration_name"
      name={@field_name}
      type="text"
      label={dgettext("dashboard_calendar_providers", "Integration Name")}
      value={@suggested_name}
      required
      phx-blur={JS.push("validate_field", value: %{"field" => "name"}, target: @target)}
      placeholder={@placeholder}
      errors={FormValidationHelpers.field_errors(@form_errors, :name)}
      icon="hero-tag"
    />
    """
  end

  attr :discovered_calendars, :list, required: true
  @spec calendar_selection(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_selection(assigns) do
    ~H"""
    <div class="space-y-3">
      <h4 class="label">{dgettext("dashboard_calendar_providers", "Select calendars to sync:")}</h4>
      <div class="brand-card p-4">
        <%= if @discovered_calendars == [] do %>
          <p class="text-sm text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_providers",
              "No calendars were discovered. Double-check your credentials or try again."
            )}
          </p>
        <% else %>
          <%= for calendar <- @discovered_calendars do %>
            <% calendar_path = calendar.path || calendar.href %>
            <div class="flex items-center space-x-3 p-3 rounded-lg hover:bg-white/20 transition-colors">
              <.input
                type="checkbox"
                name="selected_calendars[]"
                value={calendar_path}
                checked
                id={"calendar-#{calendar_path |> String.replace("/", "-")}"}
              />
              <label
                for={"calendar-#{calendar_path |> String.replace("/", "-")}"}
                class="flex-1 cursor-pointer"
              >
                <div class="font-semibold text-tymeslot-800">
                  {calendar.name || dgettext("dashboard_calendar_providers", "Unnamed Calendar")}
                </div>
                <div class="text-sm text-tymeslot-600">{calendar_path}</div>
              </label>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :value, :string, required: true
  attr :tooltip, :string, required: true
  attr :name, :string, default: "integration[url]"

  @spec locked_url_field(map()) :: Phoenix.LiveView.Rendered.t()
  def locked_url_field(assigns) do
    ~H"""
    <div class="form-field-wrapper">
      <div class="flex items-center gap-1.5 mb-2">
        <span class="label mb-0!">{dgettext("dashboard_calendar_providers", "Server URL")}</span>
        <span class="text-tymeslot-400 shrink-0">
          <svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
              clip-rule="evenodd"
            />
          </svg>
        </span>
      </div>
      <input type="hidden" name={@name} value={@value} />
      <div class="relative" title={@tooltip}>
        <div class="absolute left-4 top-1/2 -translate-y-1/2 text-tymeslot-300 pointer-events-none">
          <TymeslotWeb.Components.CoreComponents.Icons.icon name="hero-lock-closed" class="w-5 h-5" />
        </div>
        <input
          type="text"
          value={@value}
          disabled
          class="input input-with-icon opacity-60 cursor-not-allowed bg-tymeslot-100 text-tymeslot-500"
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true
  attr :error, :string, default: nil
  attr :errors, :list, default: []
  attr :target, :any, default: nil
  attr :field, :string, required: true
  attr :type, :string, default: "text"
  attr :icon, :string, default: nil

  defp text_field(assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type={@type}
      label={@label}
      value={@value}
      required
      phx-blur={JS.push("validate_field", value: %{"field" => @field}, target: @target)}
      placeholder={@placeholder}
      errors={if @error, do: [@error], else: @errors}
      icon={@icon}
    />
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true
  attr :error, :string, default: nil
  attr :errors, :list, default: []
  attr :target, :any, default: nil
  attr :field, :string, default: "password"

  defp password_field(assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="password"
      label={@label}
      value={@value}
      required
      phx-blur={JS.push("validate_field", value: %{"field" => @field}, target: @target)}
      placeholder={@placeholder}
      errors={if @error, do: [@error], else: @errors}
      icon="hero-lock-closed"
    />
    """
  end

  attr :error, :string, required: true
  @spec error_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def error_banner(assigns) do
    ~H"""
    <div class="brand-card p-3 bg-red-50/50 border border-red-200/50">
      <p class="text-sm text-red-600 flex items-center">
        <svg class="w-4 h-4 mr-2" fill="currentColor" viewBox="0 0 20 20">
          <path
            fill-rule="evenodd"
            d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z"
            clip-rule="evenodd"
          />
        </svg>
        {@error}
      </p>
    </div>
    """
  end

  defp form_level_error(form_errors) do
    [
      Map.get(form_errors, :discovery),
      Map.get(form_errors, :base),
      Map.get(form_errors, :generic)
    ]
    |> Enum.find(& &1)
    |> normalize_error_message()
  end

  defp normalize_error_message(nil), do: nil
  defp normalize_error_message([message | _rest]) when is_binary(message), do: message
  defp normalize_error_message(message) when is_binary(message), do: message

  defp normalize_error_message(_other),
    do: dgettext("dashboard_calendar_providers", "Something went wrong. Please try again.")
end
