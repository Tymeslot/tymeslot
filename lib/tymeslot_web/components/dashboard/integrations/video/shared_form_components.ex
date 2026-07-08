defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents do
  @moduledoc """
  Shared HEEx components for video integration configuration forms.
  Provides consistent, reusable form elements across all video providers.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders a standard integration name field with icon.
  """
  attr :form_errors, :map, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :target, :any, required: true

  @spec integration_name_field(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_name_field(assigns) do
    ~H"""
    <div>
      <label for="integration_name" class="label">
        {dgettext("dashboard_integrations", "Integration Name")}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <svg class="w-5 h-5 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
          name="integration[name]"
          value={@value}
          phx-blur={JS.push("validate_field", value: %{"field" => "name"}, target: @target)}
          required
          class={[
            "input input-with-icon w-full",
            if(FormValidationHelpers.field_errors(@form_errors, :name) != [], do: "input-error", else: "")
          ]}
          placeholder={@placeholder || dgettext("dashboard_integrations", "My Video Integration")}
        />
      </div>
      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :name) do %>
        <p class="form-error">{error}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a URL field with globe icon.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true
  attr :form_errors, :map, required: true
  attr :error_key, :atom, required: true
  attr :target, :any, required: true
  attr :helper_text, :string, default: nil

  @spec url_field(map()) :: Phoenix.LiveView.Rendered.t()
  def url_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="label">
        {@label}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <svg class="w-5 h-5 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 919-9"
            />
          </svg>
        </div>
        <input
          type="url"
          id={@id}
          name={@name}
          value={@value}
          phx-blur={JS.push("validate_field", value: %{"field" => Atom.to_string(@error_key)}, target: @target)}
          required
          class={[
            "input input-with-icon w-full",
            if(FormValidationHelpers.field_errors(@form_errors, @error_key) != [], do: "input-error", else: "")
          ]}
          placeholder={@placeholder}
        />
      </div>
      <%= if FormValidationHelpers.field_errors(@form_errors, @error_key) != [] do %>
        <%= for error <- FormValidationHelpers.field_errors(@form_errors, @error_key) do %>
          <p class="form-error">{error}</p>
        <% end %>
      <% else %>
        <%= if @helper_text do %>
          <p class="mt-2 text-xs text-tymeslot-500">{@helper_text}</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an API key field with key icon (password-masked).
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :form_errors, :map, required: true
  attr :error_key, :atom, default: :api_key
  attr :target, :any, required: true
  attr :helper_text, :string, default: nil

  @spec api_key_field(map()) :: Phoenix.LiveView.Rendered.t()
  def api_key_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="label">
        {@label || dgettext("dashboard_integrations", "API Key")}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <svg class="w-5 h-5 text-tymeslot-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"
            />
          </svg>
        </div>
        <input
          type="password"
          id={@id}
          name={@name}
          value={@value}
          phx-blur={JS.push("validate_field", value: %{"field" => Atom.to_string(@error_key)}, target: @target)}
          required
          class={[
            "input input-with-icon w-full",
            if(FormValidationHelpers.field_errors(@form_errors, @error_key) != [], do: "input-error", else: "")
          ]}
          placeholder={@placeholder || dgettext("dashboard_integrations", "Your API key")}
        />
      </div>
      <%= if FormValidationHelpers.field_errors(@form_errors, @error_key) != [] do %>
        <%= for error <- FormValidationHelpers.field_errors(@form_errors, @error_key) do %>
          <p class="form-error">{error}</p>
        <% end %>
      <% else %>
        <%= if @helper_text do %>
          <p class="mt-2 text-xs text-tymeslot-500">{@helper_text}</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a standard error banner for base-level errors.
  """
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

  @doc """
  Renders the standard form header with close button.
  """
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :target, :any, required: true

  @spec form_header(map()) :: Phoenix.LiveView.Rendered.t()
  def form_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6">
      <div class="flex items-center">
        <div class="text-turquoise-600 mr-3">
          <%= Phoenix.HTML.raw(@icon) %>
        </div>
        <h3 class="text-lg font-semibold text-tymeslot-800">{@title}</h3>
      </div>
      <UIComponents.close_button target={@target} />
    </div>
    """
  end
end
