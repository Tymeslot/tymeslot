defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents do
  @moduledoc """
  Shared HEEx components for calendar integration configuration forms.
  """

  use Phoenix.Component

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

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
  attr :name_placeholder, :string, default: "My Calendar"
  attr :url_placeholder, :string, default: "https://example.com/remote.php/dav"
  attr :username_placeholder, :string, default: "Username"
  attr :password_placeholder, :string, default: "Password"

  @spec config_form(map()) :: Phoenix.LiveView.Rendered.t()
  def config_form(assigns) do
    ~H"""
    <div class="border-t border-turquoise-200/30 my-6"></div>

    <%= if @show_calendar_selection do %>
      <form phx-submit="add_integration" phx-target={@target} class="space-y-6">
        <.integration_name_field
          form_errors={@form_errors}
          suggested_name={@suggested_name}
          placeholder={@name_placeholder}
        />

        <input type="hidden" name="integration[provider]" value={@provider} />

        <.calendar_selection discovered_calendars={@discovered_calendars} />

        <input type="hidden" name="integration[url]" value={@discovery_credentials[:url]} />
        <input type="hidden" name="integration[username]" value={@discovery_credentials[:username]} />
        <input type="hidden" name="integration[password]" value={@discovery_credentials[:password]} />

        <%= if error = Map.get(@form_errors, :base) do %>
          <.error_banner error={error} />
        <% end %>

        <div class="flex justify-end mt-6 pt-4 border-t border-turquoise-200/30">
          <UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    <% else %>
      <form
        phx-submit="discover_calendars"
        phx-change="track_form_change"
        phx-target={@myself}
        class="space-y-6"
      >
        <input type="hidden" name="integration[provider]" value={@provider} />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.integration_name_field
            form_errors={@form_errors}
            suggested_name={Map.get(@form_values, "name", "")}
            placeholder={@name_placeholder}
            field_name="integration[name]"
            blur_event="validate_field"
            myself={@myself}
          />

          <.text_field
            id="discovery_url"
            name="integration[url]"
            label="Server URL"
            value={Map.get(@form_values, "url", "")}
            placeholder={@url_placeholder}
            error={Map.get(@form_errors, :url)}
            myself={@myself}
            field="url"
          />

          <.text_field
            id="discovery_username"
            name="integration[username]"
            label="Username"
            value={Map.get(@form_values, "username", "")}
            placeholder={@username_placeholder}
            error={Map.get(@form_errors, :username)}
            myself={@myself}
            field="username"
          />

          <.password_field
            id="discovery_password"
            name="integration[password]"
            label="Password / App Password"
            value={Map.get(@form_values, "password", "")}
            placeholder={@password_placeholder}
            error={Map.get(@form_errors, :password)}
            myself={@myself}
            field="password"
          />
        </div>

        <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
          <UIComponents.secondary_button
            label="Cancel"
            icon="hero-x-mark"
            target={@target}
          />

          <UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    <% end %>
    """
  end

  attr :form_errors, :map, required: true
  attr :suggested_name, :string, required: true
  attr :placeholder, :string, required: true
  attr :field_name, :string, default: "integration[name]"
  attr :blur_event, :string, default: nil
  attr :myself, :any, default: nil

  @spec integration_name_field(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_name_field(assigns) do
    ~H"""
    <div>
      <label for="integration_name" class="label">
        Integration Name
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <svg class="w-5 h-5 text-neutral-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"
            />
          </svg>
        </div>
        <input
          type="text"
          id="integration_name"
          name={@field_name}
          value={@suggested_name}
          required
          phx-blur={@blur_event}
          phx-value-field="name"
          phx-target={@myself}
          class={[
            "glass-input pl-10 w-full",
            if(Map.get(@form_errors, :name), do: "input-error", else: "")
          ]}
          placeholder={@placeholder}
        />
      </div>
      <%= if error = Map.get(@form_errors, :name) do %>
        <p class="form-error">{error}</p>
      <% end %>
    </div>
    """
  end

  attr :discovered_calendars, :list, required: true
  @spec calendar_selection(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_selection(assigns) do
    ~H"""
    <div class="space-y-3">
      <h4 class="label">Select calendars to sync:</h4>
      <div class="glass-card p-4">
        <%= for calendar <- @discovered_calendars do %>
          <% calendar_path = calendar.path || calendar.href %>
          <div class="flex items-center space-x-3 p-3 rounded-lg hover:bg-white/20 transition-colors">
            <input
              type="checkbox"
              name="selected_calendars[]"
              value={calendar_path}
              checked
              id={"calendar-#{calendar_path |> String.replace("/", "-")}"}
              class="checkbox"
            />
            <label
              for={"calendar-#{calendar_path |> String.replace("/", "-")}"}
              class="flex-1 cursor-pointer"
            >
              <div class="font-semibold text-gray-800">
                {calendar.name || "Unnamed Calendar"}
              </div>
              <div class="text-sm text-gray-600">{calendar_path}</div>
            </label>
          </div>
        <% end %>
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
  attr :myself, :any, default: nil
  attr :field, :string, required: true

  defp text_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="label">
        {@label}
      </label>
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        required
        phx-blur="validate_field"
        phx-value-field={@field}
        phx-target={@myself}
        class={[
          "glass-input w-full",
          if(@error, do: "input-error", else: "")
        ]}
        placeholder={@placeholder}
      />
      <%= if @error do %>
        <p class="form-error">{@error}</p>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true
  attr :error, :string, default: nil
  attr :myself, :any, default: nil
  attr :field, :string, default: "password"

  defp password_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="label">
        {@label}
      </label>
      <input
        type="password"
        id={@id}
        name={@name}
        value={@value}
        required
        phx-blur="validate_field"
        phx-value-field={@field}
        phx-target={@myself}
        class={[
          "glass-input w-full",
          if(@error, do: "input-error", else: "")
        ]}
        placeholder={@placeholder}
      />
      <%= if @error do %>
        <p class="form-error">{@error}</p>
      <% end %>
    </div>
    """
  end

  attr :error, :string, required: true
  @spec error_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def error_banner(assigns) do
    ~H"""
    <div class="glass-card p-3 bg-red-50/50 border border-red-200/50">
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
end
