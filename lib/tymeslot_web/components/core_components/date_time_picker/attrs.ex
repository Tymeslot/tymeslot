defmodule TymeslotWeb.Components.CoreComponents.DateTimePicker.Attrs do
  @moduledoc false

  # The attributes all three pickers take, declared once: `attr` has no way to
  # share a list between function components.

  alias Phoenix.HTML.FormField

  defmacro picker_attrs do
    quote do
      attr :id, :string, doc: "required unless `field` is given; must be unique on the page"
      attr :name, :any
      attr :label, :string, default: nil
      attr :value, :any
      attr :field, FormField, doc: "a form field struct, for example: @form[:starts_on]"
      attr :errors, :list, default: []
      attr :required, :boolean, default: false
      attr :disabled, :boolean, default: false

      attr :placeholder, :string,
        default: nil,
        doc: "defaults to a sample in the viewer's format"

      attr :min, :any,
        default: nil,
        doc: "the earliest ISO date (or `HH:MM` time) offered; the server still validates"

      attr :max, :any, default: nil, doc: "the latest ISO date (or `HH:MM` time) offered"

      attr :variant, :atom,
        default: :default,
        values: [:default, :compact, :inline],
        doc: "`:compact` for a row of controls, `:inline` for a field set in a sentence"

      attr :week_start, :atom,
        default: nil,
        doc: "`:monday` or `:sunday`; overrides the viewer's"

      attr :time_format, :string, default: nil, doc: "`12h` or `24h`; overrides the viewer's"
      attr :class, :string, default: nil

      attr :rest, :global,
        include: ~w(form),
        doc: """
        `phx-*` and `form` go on the hidden input that posts the value, `aria-*`
        and `autofocus` on the typed field, anything else on the outer element.
        """

      slot :description, doc: "Optional helper text rendered between the label and the field."
    end
  end
end
