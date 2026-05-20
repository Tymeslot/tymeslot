defmodule TymeslotWeb.Components.CoreComponents.Forms do
  @moduledoc """
  Unified form components for the entire application.

  For forms that need "clear-on-type, validate-on-blur" error UX — where an
  error disappears as soon as the user starts typing and reappears only on
  blur or save — pair these components with
  `TymeslotWeb.Live.Shared.FormValidationHelpers` and pass each input an
  explicit `errors={FormValidationHelpers.field_errors(...)}` attribute.
  Do not use the `field=` shortcut for that UX, because `field.errors` will
  re-add errors from the live changeset and defeat the clear-on-type
  behaviour.
  """
  use Phoenix.Component

  # ========== UNIFIED INPUT ==========

  @doc """
  Renders a unified input field with label, icons, and error handling.
  Replaces all legacy input components (Auth, FormSystem, etc.)

  ## Examples

      <.input field={@form[:email]} type="email" label="Email" icon="hero-envelope" />
      <.input name="search" value="" label="Search" placeholder="Search..." />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(checkbox color date datetime-local email file month number password range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "placeholder option shown in select inputs"
  attr :options, :list, doc: "the options to render for select inputs"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :required, :boolean, default: false
  attr :placeholder, :string, default: nil
  attr :icon, :string, default: nil, doc: "optional hero icon name rendered inside the input"

  attr :validate_on_blur, :boolean,
    default: false,
    doc: "when true, triggers validation on blur rather than on change"

  attr :class, :string, default: nil
  attr :rows, :integer, default: 4, doc: "the number of rows for textarea inputs"

  attr :hidden_input, :boolean,
    default: true,
    doc: "whether to render a hidden input for checkboxes"

  attr :min, :any
  attr :max, :any
  attr :step, :any
  attr :minlength, :any
  attr :maxlength, :any
  attr :pattern, :any
  attr :rest, :global

  slot :inner_block
  slot :leading_icon
  slot :trailing_icon
  slot :description, doc: "Optional helper text rendered between the label and the input."

  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns[:id] || field.id)
    |> assign(name: assigns[:name] || field.name)
    |> assign(value: assigns[:value] || field.value)
    |> assign(errors: (assigns[:errors] || []) ++ field.errors)
    |> input()
  end

  def input(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> nil end)
      |> assign_new(:name, fn -> nil end)
      |> assign_new(:checked, fn -> nil end)
      |> assign_new(:value, fn -> nil end)

    ~H"""
    <div class={["form-field-wrapper", @class]}>
      <%= if @label do %>
        <.label for={@id}>
          {@label}
          <%= if @required do %>
            <span class="text-red-500 ml-0.5">*</span>
          <% end %>
        </.label>
      <% end %>

      <%= if @description != [] do %>
        <p class="text-token-xs text-tymeslot-500 font-medium normal-case tracking-normal -mt-1 mb-2">
          {render_slot(@description)}
        </p>
      <% end %>

      <div class="relative group">
        <%= if @icon || render_slot(@leading_icon) do %>
          <div class="absolute left-4 top-1/2 -translate-y-1/2 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors duration-300 pointer-events-none">
            <%= if @icon do %>
              <TymeslotWeb.Components.CoreComponents.Icons.icon name={@icon} class="w-5 h-5" />
            <% else %>
              {render_slot(@leading_icon)}
            <% end %>
          </div>
        <% end %>

        <.input_element
          id={@id}
          name={@name}
          type={@type}
          value={@value}
          checked={@checked}
          placeholder={@placeholder}
          required={@required}
          errors={@errors}
          has_leading_icon={@icon || render_slot(@leading_icon)}
          has_trailing_icon={render_slot(@trailing_icon)}
          validate_on_blur={@validate_on_blur}
          options={assigns[:options]}
          prompt={@prompt}
          multiple={@multiple}
          hidden_input={@hidden_input}
          rest={@rest}
        />

        <%= if render_slot(@trailing_icon) do %>
          <div class="absolute right-4 top-1/2 -translate-y-1/2 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors duration-300 pointer-events-none">
            {render_slot(@trailing_icon)}
          </div>
        <% end %>

        {render_slot(@inner_block)}
      </div>

      <.field_error errors={@errors} />
    </div>
    """
  end

  defp input_element(%{type: "select"} = assigns) do
    assigns = assign_new(assigns, :rest, fn -> %{} end)

    ~H"""
    <select
      id={@id}
      name={@name}
      multiple={@multiple}
      class={[
        "input appearance-none",
        @has_leading_icon && "input-with-icon",
        @has_trailing_icon && "input-with-trailing-icon",
        @errors != [] && "input-error"
      ]}
      {@rest}
    >
      <%= if @prompt do %>
        <option value="">{@prompt}</option>
      <% end %>
      {Phoenix.HTML.Form.options_for_select(@options, @value)}
    </select>
    """
  end

  defp input_element(%{type: "textarea"} = assigns) do
    assigns =
      assigns
      |> assign_new(:rest, fn -> %{} end)
      |> assign_new(:rows, fn -> 4 end)

    ~H"""
    <textarea
      id={@id}
      name={@name}
      rows={@rows}
      placeholder={@placeholder}
      class={[
        "input min-h-[120px] py-3",
        @has_leading_icon && "input-with-icon",
        @has_trailing_icon && "input-with-trailing-icon",
        @errors != [] && "input-error"
      ]}
      {@rest}
    >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    """
  end

  defp input_element(%{type: "checkbox"} = assigns) do
    assigns =
      assigns
      |> assign(:is_choice, String.ends_with?(assigns[:name] || "", "[]"))
      |> assign_new(:checked, fn -> false end)
      |> assign_new(:unchecked_value, fn -> "false" end)
      |> assign_new(:checked_value, fn -> "true" end)
      |> assign_new(:rest, fn -> %{} end)

    ~H"""
    <input :if={@hidden_input && !@is_choice} type="hidden" name={@name} value={@unchecked_value} />
    <input
      type="checkbox"
      id={@id}
      name={@name}
      value={if @is_choice, do: @value || "", else: @checked_value}
      checked={
        if @is_choice do
          @checked == true
        else
          Phoenix.HTML.Form.normalize_value("checkbox", @value) ==
            Phoenix.HTML.Form.normalize_value("checkbox", @checked_value)
        end
      }
      class="checkbox w-5 h-5 rounded border-tymeslot-300 text-turquoise-600 focus:ring-turquoise-500"
      {@rest}
    />
    """
  end

  defp input_element(assigns) do
    assigns = assign_new(assigns, :rest, fn -> %{} end)

    ~H"""
    <input
      type={@type}
      id={@id}
      name={@name}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      placeholder={@placeholder}
      class={[
        "input",
        @has_leading_icon && "input-with-icon",
        @has_trailing_icon && "input-with-trailing-icon",
        @errors != [] && "input-error"
      ]}
      {@rest}
    />
    """
  end

  # ========== HELPERS ==========

  @doc """
  Renders a label.
  """
  attr :for, :any, default: nil
  slot :inner_block, required: true

  @spec label(map()) :: Phoenix.LiveView.Rendered.t()
  def label(assigns) do
    ~H"""
    <label for={@for} class="label mb-2 block">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Renders a field error message.
  """
  attr :errors, :list, default: []

  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns) do
    ~H"""
    <%= if Enum.any?(@errors) do %>
      <div class="mt-2 flex items-center gap-2 text-red-600 font-bold text-sm">
        <TymeslotWeb.Components.CoreComponents.Icons.icon
          name="hero-exclamation-circle-solid"
          class="w-4 h-4"
        />
        <div class="flex flex-col">
          <%= for error <- @errors do %>
            <span>{translate_error(error)}</span>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Translates an error message.
  """
  @spec translate_error(any()) :: String.t()
  def translate_error({msg, opts}) do
    # When using gettext, we should pass the compiled message
    # For now, we'll just do a simple string replacement
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  def translate_error(msg) when is_binary(msg), do: msg
  def translate_error(other), do: inspect(other)

  # ========== PASSWORD REQUIREMENTS ==========

  @doc """
  Renders a list of password requirements.
  """
  attr :class, :string, default: nil

  @spec password_requirements(map()) :: Phoenix.LiveView.Rendered.t()
  def password_requirements(assigns) do
    ~H"""
    <div id="password-requirements" class="mt-2 text-xs sm:text-sm space-y-1.5">
      <p class="text-tymeslot-500 font-bold uppercase tracking-wider text-token-2xs">
        Password must contain:
      </p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 sm:gap-x-4">
        <ul class="space-y-1">
          <li id="req-length" class="flex items-center text-tymeslot-600 font-medium">
            <svg
              class="w-3.5 h-3.5 mr-1.5 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <circle cx="12" cy="12" r="10" stroke-width="2.5" />
            </svg>
            <span class="text-xs">At least 8 characters</span>
          </li>
          <li id="req-lowercase" class="flex items-center text-tymeslot-600 font-medium">
            <svg
              class="w-3.5 h-3.5 mr-1.5 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <circle cx="12" cy="12" r="10" stroke-width="2.5" />
            </svg>
            <span class="text-xs">One lowercase letter</span>
          </li>
        </ul>
        <ul class="space-y-1">
          <li id="req-uppercase" class="flex items-center text-tymeslot-600 font-medium">
            <svg
              class="w-3.5 h-3.5 mr-1.5 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <circle cx="12" cy="12" r="10" stroke-width="2.5" />
            </svg>
            <span class="text-xs">One uppercase letter</span>
          </li>
          <li id="req-number" class="flex items-center text-tymeslot-600 font-medium">
            <svg
              class="w-3.5 h-3.5 mr-1.5 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <circle cx="12" cy="12" r="10" stroke-width="2.5" />
            </svg>
            <span class="text-xs">One number</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # ========== FORM LAYOUT ==========

  @doc """
  Form wrapper with consistent styling and submission handling.
  """
  attr :for, :any, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(phx-change phx-submit phx-target)
  slot :inner_block, required: true

  @spec form_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def form_wrapper(assigns) do
    ~H"""
    <.form
      for={@for}
      id={@id}
      class={["space-y-6", @class]}
      {@rest}
    >
      {render_slot(@inner_block, @for)}
    </.form>
    """
  end
end
