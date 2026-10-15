defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents do
  @moduledoc """
  Shared HEEx components for video integration configuration forms.
  Provides consistent, reusable form elements across all video providers.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Icons
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
        {dgettext("dashboard_video", "Integration Name")}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <Icons.icon name="hero-tag" class="w-5 h-5 text-tymeslot-400" />
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
            if(FormValidationHelpers.field_errors(@form_errors, :name) != [],
              do: "input-error",
              else: ""
            )
          ]}
          placeholder={@placeholder || dgettext("dashboard_video", "My Video Integration")}
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

  attr :validate_on_blur, :boolean,
    default: true,
    doc: "pushes `validate_field` to `target` when the input loses focus"

  @spec url_field(map()) :: Phoenix.LiveView.Rendered.t()
  def url_field(assigns) do
    errors = FormValidationHelpers.field_errors(assigns.form_errors, assigns.error_key)

    # Errors replace the helper text, so the input is described by whichever
    # of the two is on the page.
    describedby =
      cond do
        errors != [] -> "#{assigns.id}-error"
        assigns.helper_text -> "#{assigns.id}-help"
        true -> nil
      end

    assigns = assign(assigns, errors: errors, describedby: describedby)

    ~H"""
    <div>
      <label for={@id} class="label">
        {@label}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <Icons.icon name="hero-globe-alt" class="w-5 h-5 text-tymeslot-400" />
        </div>
        <input
          type="url"
          id={@id}
          name={@name}
          value={@value}
          phx-blur={
            @validate_on_blur &&
              JS.push("validate_field",
                value: %{"field" => Atom.to_string(@error_key)},
                target: @target
              )
          }
          required
          aria-describedby={@describedby}
          aria-invalid={@errors != [] && "true"}
          class={["input input-with-icon w-full", @errors != [] && "input-error"]}
          placeholder={@placeholder}
          {UIComponents.server_url_attrs()}
        />
      </div>
      <div :if={@errors != []} id={"#{@id}-error"}>
        <p :for={error <- @errors} class="form-error">{error}</p>
      </div>
      <p
        :if={@errors == [] && @helper_text}
        id={"#{@id}-help"}
        class="mt-2 text-token-xs text-tymeslot-500"
      >
        {@helper_text}
      </p>
    </div>
    """
  end

  @doc """
  Renders a read-only server address for a provider whose host is fixed.

  The value is shown but never submitted: the provider supplies its own host
  server-side. The input stays `readonly` rather than `disabled` so keyboard
  and screen reader users can still reach it; it points at the tooltip and
  the helper text through `aria-describedby`, and focusing it shows the
  tooltip. The info icon is decorative and only reveals the tooltip on hover.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :tooltip, :string, required: true
  attr :helper_text, :string, default: nil

  @spec locked_host_field(map()) :: Phoenix.LiveView.Rendered.t()
  def locked_host_field(assigns) do
    assigns =
      assign(
        assigns,
        :describedby,
        Enum.join(
          ["#{assigns.id}-tooltip" | List.wrap(assigns.helper_text && "#{assigns.id}-help")],
          " "
        )
      )

    ~H"""
    <div class="group/field">
      <div class="flex items-center gap-1.5 mb-2">
        <label for={@id} class="label mb-0">
          {dgettext("dashboard_video", "Server URL")}
        </label>
        <span class="group relative inline-flex text-tymeslot-500 shrink-0">
          <Icons.icon name="hero-information-circle-mini" class="w-4 h-4" />
          <span
            id={"#{@id}-tooltip"}
            role="tooltip"
            class="invisible opacity-0 group-hover:visible group-hover:opacity-100 group-focus-within/field:visible group-focus-within/field:opacity-100 transition-opacity absolute left-1/2 bottom-full z-10 mb-2 w-64 -translate-x-1/2 rounded-token-lg bg-tymeslot-800 px-3 py-2 text-token-xs font-medium text-white shadow-glass-md"
          >
            {@tooltip}
          </span>
        </span>
      </div>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-tymeslot-300">
          <Icons.icon name="hero-lock-closed" class="w-5 h-5" />
        </div>
        <input
          type="text"
          id={@id}
          value={@value}
          readonly
          aria-describedby={@describedby}
          class="input input-with-icon w-full cursor-not-allowed bg-tymeslot-100 text-tymeslot-600"
        />
      </div>
      <p :if={@helper_text} id={"#{@id}-help"} class="mt-2 text-token-xs text-tymeslot-500">
        {@helper_text}
      </p>
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
        {@label || dgettext("dashboard_video", "API Key")}
      </label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <Icons.icon name="hero-key" class="w-5 h-5 text-tymeslot-400" />
        </div>
        <input
          type="password"
          id={@id}
          name={@name}
          value={@value}
          phx-blur={
            JS.push("validate_field",
              value: %{"field" => Atom.to_string(@error_key)},
              target: @target
            )
          }
          required
          class={[
            "input input-with-icon w-full",
            if(FormValidationHelpers.field_errors(@form_errors, @error_key) != [],
              do: "input-error",
              else: ""
            )
          ]}
          placeholder={@placeholder || dgettext("dashboard_video", "Your API key")}
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
  Renders a credential input with an icon: a login or client id, or a secret.

  A secret is rendered without a value, so a typed or stored secret never
  comes back into the page. Browsers ignore `autocomplete="off"` on a password
  input and a password manager would fill in the organiser's own Tymeslot
  password, so a secret is marked `new-password`, which password managers do
  not fill; any other credential stays `off`, so the pair never reads as a
  sign-in form. Field errors show under the input, followed by the slot, which
  is where help text goes.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :type, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil, doc: "left unset for a secret, which is never rendered"
  attr :describedby, :string, required: true
  attr :disabled, :boolean, default: false
  attr :placeholder, :string, default: nil

  attr :required, :boolean,
    default: false,
    doc: "off where a blank field means 'keep what is stored'"

  attr :errors, :list, default: []
  slot :inner_block

  @spec credential_input(map()) :: Phoenix.LiveView.Rendered.t()
  def credential_input(assigns) do
    ~H"""
    <div>
      <label for={@id} class="label">{@label}</label>
      <div class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none text-tymeslot-400">
          <Icons.icon name={@icon} class="w-5 h-5" />
        </div>
        <input
          type={@type}
          id={@id}
          name={@name}
          value={@value}
          autocomplete={if @type == "password", do: "new-password", else: "off"}
          disabled={@disabled}
          placeholder={@placeholder}
          required={@required}
          aria-describedby={@describedby}
          class={["input input-with-icon w-full", @errors != [] && "input-error"]}
        />
      </div>
      <p :for={error <- @errors} class="form-error">{error}</p>
      {render_slot(@inner_block)}
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
    <div role="alert" class="brand-card p-3 bg-red-50/50 border border-red-200/50">
      <p class="text-sm text-red-600 flex items-center">
        <Icons.icon name="hero-exclamation-circle-mini" class="w-4 h-4 mr-2" />
        {@error}
      </p>
    </div>
    """
  end

  @doc """
  Returns the form-level error message, if any, for the `:base` key that
  `TymeslotWeb.Helpers.IntegrationProviders.reason_to_form_errors/1` and
  `duplicate_integration` handling assign it under. `nil` when there is none.
  """
  @spec form_level_error(map()) :: String.t() | nil
  def form_level_error(form_errors), do: Map.get(form_errors, :base)
end
