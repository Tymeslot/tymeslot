defmodule TymeslotWeb.Components.CoreComponents.Select do
  @moduledoc """
  The select field: a button that opens an in-house option list, or, on a touch
  device, the system's own picker.

  Every value is posted by a hidden input named like the field, so a form and
  its changeset see what a plain select would send, and a choice fires `input`
  on that input, so `phx-change` works unchanged, on the form or on the field
  (`@rest` carries `phx-*` attributes onto the hidden input).

  The options are rendered once, as a native select element. On a device whose
  primary pointer is coarse that control is the visible one, because the system
  wheel or sheet is the better experience on a phone; everywhere else it stays
  hidden and the `Select` hook (`assets/js/hooks/select.js`) draws an ARIA
  listbox from its options when the button is pressed, in a `dropdown_panel/1`
  placed by `assets/js/floating_panel.js`. Which of the two a device gets is a
  CSS decision (`.select-native`), so a page never flashes the wrong one.
  """
  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents.Dropdown, only: [dropdown_panel: 1]
  import TymeslotWeb.Components.CoreComponents.Forms, only: [label: 1, field_error: 1]
  import TymeslotWeb.Components.CoreComponents.Icons, only: [icon: 1]

  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField

  @doc """
  Renders a select field.

  ## Examples

      <.select id="meeting-length" name="length" value={@length} options={@lengths} label="Length" />
      <.select id="owner" field={@form[:owner_id]} options={@owners} prompt="Choose one" />

  `id` is required: the hook hangs off it, so it must be unique on the page,
  which a `name` repeated per row (`start`, `end`) cannot promise.
  """
  attr :id, :string, required: true
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :field, FormField, doc: "a form field struct, for example: @form[:timezone]"

  attr :options, :list,
    required: true,
    doc: "as `Phoenix.HTML.Form.options_for_select/2` takes, option groups included"

  attr :prompt, :any,
    default: nil,
    doc: "the empty choice, shown first; `nil` or `false` for none"

  attr :errors, :list, default: []
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :icon, :string, default: nil, doc: "optional hero icon name rendered inside the field"
  attr :compact, :boolean, default: false, doc: "the small size, for a row of inline controls"
  attr :class, :string, default: nil

  attr :rest, :global,
    include: ~w(form),
    doc: """
    `phx-*` and `form` go on the hidden input that posts the value, `aria-*` on
    the control, and anything else (a `data-testid`, say) on the outer element.
    """

  slot :description, doc: "Optional helper text rendered between the label and the field."

  @spec select(map()) :: Phoenix.LiveView.Rendered.t()
  def select(%{field: %FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, name: assigns[:name] || field.name)
    |> assign(value: if(is_nil(assigns[:value]), do: field.value, else: assigns.value))
    |> assign(errors: (assigns[:errors] || []) ++ field.errors)
    |> select()
  end

  def select(assigns) do
    assigns = assign_new(assigns, :value, fn -> nil end)

    {value, selected_label} = selected(assigns)

    error_id = assigns.errors != [] && "#{assigns.id}-error"

    assigns =
      assign(
        assigns,
        Map.merge(split_rest(assigns.rest, error_id), %{
          selected_value: value,
          selected_label: selected_label,
          error_id: error_id,
          named?: assigns.label != nil or assigns.rest[:"aria-label"] != nil
        })
      )

    ~H"""
    <div
      id={"#{@id}-field"}
      class={["form-field-wrapper select-field", @compact && "select-field--compact", @class]}
      phx-hook="Select"
      {@root_rest}
    >
      <.label :if={@label} id={"#{@id}-label"} for={@id}>
        {@label}
        <span :if={@required} class="text-red-500 ml-0.5">*</span>
      </.label>
      <span :if={!@label && @rest[:"aria-label"]} id={"#{@id}-label"} hidden>
        {@rest[:"aria-label"]}
      </span>

      <p
        :if={@description != []}
        class="text-token-xs text-tymeslot-500 font-medium normal-case tracking-normal -mt-1 mb-2"
      >
        {render_slot(@description)}
      </p>

      <div class="relative group">
        <div
          :if={@icon}
          class="select-icon absolute left-4 top-1/2 -translate-y-1/2 text-tymeslot-400 group-hover:text-turquoise-600 transition-colors duration-300 pointer-events-none"
        >
          <.icon name={@icon} class="w-5 h-5" />
        </div>

        <input
          type="hidden"
          data-select-value
          name={@name}
          value={@selected_value}
          disabled={@disabled}
          {@value_rest}
        />

        <button
          type="button"
          id={"#{@id}-trigger"}
          data-select-trigger
          class={[
            "input select-trigger",
            @icon && "input-with-icon",
            @errors != [] && "input-error"
          ]}
          disabled={@disabled}
          aria-haspopup="listbox"
          aria-expanded="false"
          aria-controls={"#{@id}-panel"}
          aria-labelledby={if(@named?, do: "#{@id}-label #{@id}-text", else: "#{@id}-text")}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@describedby}
        >
          <span
            id={"#{@id}-text"}
            data-select-text
            class={["select-value", @selected_value == "" && "select-value--placeholder"]}
          >
            {@selected_label}
          </span>
        </button>

        <%!-- raw-input: the options the listbox is drawn from, and the visible control on a touch device; it has no name because the hidden input posts the value --%>
        <select
          id={@id}
          data-select-native
          data-name={@name}
          class={[
            "input select-native",
            @icon && "input-with-icon",
            @errors != [] && "input-error"
          ]}
          disabled={@disabled}
          aria-label={@rest[:"aria-label"]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@describedby}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>

        <.icon
          name="hero-chevron-down"
          class="select-chevron absolute right-4 top-1/2 -translate-y-1/2 w-5 h-5 stroke-[2.5] text-tymeslot-500 pointer-events-none"
        />

        <.dropdown_panel
          id={"#{@id}-panel"}
          role="listbox"
          class="select-panel"
          unstyled
          panel_attrs={[
            {"popover", "manual"},
            {"phx-update", "ignore"},
            {"tabindex", "-1"},
            {"data-select-panel", true},
            {"aria-labelledby", @named? && "#{@id}-label"},
            {"aria-required", @required && "true"}
          ]}
        />
      </div>

      <.field_error errors={@errors} id={@error_id} />
    </div>
    """
  end

  # Mirrors what a browser would post: the option matching `value`, else the
  # prompt's empty value, else the first option. `false` is a value like any
  # other; only nil is none.
  defp selected(%{options: options, value: value, prompt: prompt}) do
    normalised = Enum.flat_map(options, &flatten_option/1)
    wanted = if is_nil(value), do: nil, else: to_string(value)

    case Enum.find(normalised, fn {_label, option_value} -> option_value == wanted end) do
      {label, option_value} -> {option_value, label}
      nil -> default_selection(prompt, normalised)
    end
  end

  defp default_selection(prompt, options) when prompt in [nil, false], do: first_option(options)
  defp default_selection(prompt, _options), do: {"", prompt}

  defp first_option([]), do: {"", ""}
  defp first_option([{label, value} | _rest]), do: {value, label}

  # `{label, [options]}` is an option group, as for `options_for_select/2`.
  defp flatten_option({_group, options}) when is_list(options), do: Enum.map(options, &option/1)
  defp flatten_option(option), do: [option(option)]

  defp option({label, value}), do: {to_string(label), to_string(value)}
  defp option(option) when is_list(option), do: keyword_option(option[:key], option[:value])
  defp option(option), do: {to_string(option), to_string(option)}

  defp keyword_option(label, value), do: {to_string(label), to_string(value)}

  # Sorts `@rest`: `phx-*` and `form` post with the value, `aria-*` describe the
  # control, and the rest (a `data-testid`, say) marks the field as a whole.
  defp split_rest(rest, error_id) do
    {value_rest, others} = Enum.split_with(rest, fn {key, _value} -> value_attr?(key) end)
    {aria_rest, root_rest} = Enum.split_with(others, fn {key, _value} -> aria_attr?(key) end)

    %{
      value_rest: value_rest,
      root_rest: root_rest,
      describedby: describedby(aria_rest[:"aria-describedby"], error_id)
    }
  end

  defp value_attr?(key), do: key == :form or match?("phx-" <> _rest, to_string(key))
  defp aria_attr?(key), do: match?("aria-" <> _rest, to_string(key))

  defp describedby(nil, false), do: nil
  defp describedby(explicit, false), do: explicit
  defp describedby(nil, error_id), do: error_id
  defp describedby(explicit, error_id), do: "#{explicit} #{error_id}"
end
