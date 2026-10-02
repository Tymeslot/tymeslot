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
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.UI.StatusSwitch

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
  attr :disabled, :boolean, default: false
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
      |> assign_new(:maxlength, fn -> nil end)

    error_id = assigns.id && assigns.errors != [] && "#{assigns.id}-error"

    assigns =
      assigns
      |> assign(:error_id, error_id)
      |> assign(
        :rest,
        assigns.errors
        |> error_aria(error_id)
        |> Map.merge(html_constraints(assigns))
        |> disabled_attr(assigns.disabled)
        |> required_attr(assigns.required)
        |> Map.merge(assigns.rest)
      )

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
          errors={@errors}
          has_leading_icon={@icon || render_slot(@leading_icon)}
          has_trailing_icon={render_slot(@trailing_icon)}
          validate_on_blur={@validate_on_blur}
          options={assigns[:options]}
          prompt={@prompt}
          multiple={@multiple}
          hidden_input={@hidden_input}
          maxlength={@maxlength}
          rest={@rest}
        />

        <%= if render_slot(@trailing_icon) do %>
          <div class="absolute right-4 top-1/2 -translate-y-1/2 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors duration-300 pointer-events-none">
            {render_slot(@trailing_icon)}
          </div>
        <% end %>

        {render_slot(@inner_block)}
      </div>

      <.field_error errors={@errors} id={@error_id} />
    </div>
    """
  end

  # Associates a field's error message with the control for assistive tech.
  # `aria-invalid` flags the failed state; `aria-describedby` points screen
  # readers at the `<.field_error>` region (which carries the same id).
  defp error_aria([], _error_id), do: %{}
  defp error_aria(_errors, nil), do: %{"aria-invalid" => "true"}

  defp error_aria(_errors, error_id),
    do: %{"aria-invalid" => "true", "aria-describedby" => error_id}

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
      maxlength={@maxlength}
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
      maxlength={@maxlength}
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

  # The HTML constraint attributes are *declared*, so `:global` never collects
  # them and they would otherwise be dropped on the floor: `input_element/1`
  # spreads `@rest` and nothing else. Folding them into `@rest` here is what
  # makes `maxlength={60}` reach the rendered input. Unset ones stay out of the
  # map rather than rendering as empty attributes.
  @html_constraints [:min, :max, :step, :minlength, :maxlength, :pattern]

  # `disabled` is a form attribute, not one of Phoenix's HTML globals, so it has
  # to be declared and threaded through by hand. Only the true case is merged:
  # `disabled={false}` must leave no attribute behind at all.
  defp disabled_attr(rest, true), do: Map.put(rest, :disabled, true)
  defp disabled_attr(rest, _disabled), do: rest

  # `required` is declared for the label's `*`, so it needs the same threading
  # as `disabled`. Rendering it switches on native browser validation: a form
  # that shows its own server-side errors for empty fields must carry
  # `novalidate`, which keeps the attribute for assistive technology while
  # leaving the error messages to the app.
  defp required_attr(rest, true), do: Map.put(rest, :required, true)
  defp required_attr(rest, _required), do: rest

  defp html_constraints(assigns) do
    Map.reject(
      Map.new(@html_constraints, &{&1, assigns[&1]}),
      fn {_key, value} -> is_nil(value) end
    )
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
  attr :id, :any, default: nil, doc: "id for aria-describedby association with the field"

  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns) do
    ~H"""
    <%= if Enum.any?(@errors) do %>
      <div
        id={@id}
        role="alert"
        class="mt-2 flex items-center gap-2 text-red-600 font-bold text-sm"
      >
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
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(TymeslotWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(TymeslotWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) when is_binary(msg), do: msg
  def translate_error(other), do: inspect(other)

  # ========== PASSWORD REQUIREMENTS ==========

  @doc """
  Renders the password requirements checklist.

  Driven by `PasswordValidator.rules/0` so the list always states exactly what
  the server enforces, and each item carries its pattern for the browser-side
  live ticking (see `assets/js/password_toggle.js`).
  """
  attr :class, :string, default: nil

  @spec password_requirements(map()) :: Phoenix.LiveView.Rendered.t()
  def password_requirements(assigns) do
    assigns = assign(assigns, :rules, PasswordValidator.rules())

    ~H"""
    <div id="password-requirements" class={["mt-2 text-xs sm:text-sm space-y-1.5", @class]}>
      <p class="text-tymeslot-500 font-bold uppercase tracking-wider text-token-2xs">
        {dgettext("common", "Password must contain:")}
      </p>
      <ul class="grid grid-cols-1 sm:grid-cols-2 gap-y-1 gap-x-2 sm:gap-x-4">
        <li
          :for={rule <- @rules}
          id={"req-#{rule.key}"}
          data-password-rule={rule.key}
          data-password-pattern={rule.pattern}
          class="flex items-center text-tymeslot-600 font-medium"
        >
          <svg
            class="w-3.5 h-3.5 mr-1.5 shrink-0"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <circle cx="12" cy="12" r="10" stroke-width="2.5" />
          </svg>
          <span class="text-xs">{password_rule_label(rule.key)}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp password_rule_label(:length),
    do: dgettext("common", "At least %{count} characters", count: PasswordValidator.min_length())

  defp password_rule_label(:lowercase), do: dgettext("common", "One lowercase letter")
  defp password_rule_label(:uppercase), do: dgettext("common", "One uppercase letter")
  defp password_rule_label(:number), do: dgettext("common", "One number")
  defp password_rule_label(:special), do: dgettext("common", "One special character")

  # ========== SETTING ROW ==========

  @doc """
  Renders one on/off setting: a label and a description beside the control
  that switches it, on a flat card.

      <.setting_row
        id="allow-guests-toggle"
        label="Let invitees add guests"
        description="Each guest is emailed a confirmation."
        checked={@allow_guests}
        on_change="toggle_allow_guests"
        target={@myself}
      />

  * `control={:checkbox}` (the default) makes the whole card the checkbox's
    label; `control={:switch}` renders a `StatusSwitch` at the row's end, for
    a setting that takes effect the moment it is flipped.
  * The control carries no `name`: the change is sent by `on_change` (a click
    event to `target`), so a row inside a form adds nothing to its params.
  * `disabled` with a `:disabled_reason` says why the setting cannot be
    changed; the reason is shown, and announced with the control, only while
    it is disabled. The label stays at full contrast so it can still be read.
  * Further attributes (`phx-value-*`, `data-testid`) go to the control.
  """
  attr :id, :string, required: true, doc: "The control's id"
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :control, :atom, default: :checkbox, values: [:checkbox, :switch]
  attr :checked, :boolean, required: true
  attr :on_change, :string, required: true, doc: "The click event that flips the setting"
  attr :target, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global, doc: "Extra attributes for the control"

  slot :disabled_reason, doc: "Why the setting cannot be changed; shown only while disabled"

  @spec setting_row(map()) :: Phoenix.LiveView.Rendered.t()
  def setting_row(assigns) do
    reason? = assigns.disabled and assigns.disabled_reason != []

    described_by =
      [assigns.description && "#{assigns.id}-description", reason? && "#{assigns.id}-reason"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns = assign(assigns, reason?: reason?, described_by: present(described_by))

    ~H"""
    <%= if @control == :checkbox do %>
      <Containers.card
        tag="label"
        for={@id}
        variant={:flat}
        padding={:sm}
        interactive={!@disabled}
        class={["flex items-start gap-3", @disabled && "cursor-not-allowed", @class]}
      >
        <input
          type="checkbox"
          id={@id}
          class="checkbox mt-0.5 shrink-0"
          checked={@checked}
          disabled={@disabled}
          phx-click={@on_change}
          phx-target={@target}
          aria-describedby={@described_by}
          {@rest}
        />
        <.setting_text id={@id} label={@label} description={@description} reason?={@reason?}>
          <:reason>{render_slot(@disabled_reason)}</:reason>
        </.setting_text>
      </Containers.card>
    <% else %>
      <Containers.card
        variant={:flat}
        padding={:sm}
        class={["flex items-center justify-between gap-4", @class]}
      >
        <.setting_text
          id={@id}
          label={@label}
          description={@description}
          reason?={@reason?}
          label_for={@id}
        >
          <:reason>{render_slot(@disabled_reason)}</:reason>
        </.setting_text>
        <StatusSwitch.status_switch
          id={@id}
          checked={@checked}
          on_change={@on_change}
          target={@target}
          disabled={@disabled}
          class="shrink-0"
          aria-labelledby={"#{@id}-label"}
          aria-describedby={@described_by}
          {@rest}
        />
      </Containers.card>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :reason?, :boolean, required: true
  attr :label_for, :string, default: nil
  slot :reason

  # The label is a `<label>` only for the switch, whose row is not one; inside
  # the checkbox's label it is plain text.
  defp setting_text(assigns) do
    ~H"""
    <div class="min-w-0 space-y-1">
      <%= if @label_for do %>
        <label
          for={@label_for}
          id={"#{@id}-label"}
          class="block cursor-pointer text-token-sm font-medium text-tymeslot-800"
        >
          {@label}
        </label>
      <% else %>
        <p id={"#{@id}-label"} class="text-token-sm font-medium text-tymeslot-800">{@label}</p>
      <% end %>
      <p :if={@description} id={"#{@id}-description"} class="text-token-sm text-tymeslot-600">
        {@description}
      </p>
      <p
        :if={@reason?}
        id={"#{@id}-reason"}
        class="flex items-start gap-1.5 text-token-sm font-medium text-tymeslot-700"
      >
        <Icons.icon name="hero-information-circle" class="mt-0.5 h-4 w-4 shrink-0 text-turquoise-600" />
        <span>{render_slot(@reason)}</span>
      </p>
    </div>
    """
  end

  defp present(""), do: nil
  defp present(value), do: value

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
