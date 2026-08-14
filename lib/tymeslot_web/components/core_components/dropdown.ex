defmodule TymeslotWeb.Components.CoreComponents.Dropdown do
  @moduledoc "Standardised dropdown shell: trigger button + conditionally-rendered floating panel."

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents.Icons

  attr :id, :string, required: true
  attr :open, :boolean, required: true
  attr :on_toggle, :string, required: true
  attr :on_close, :string, required: true
  attr :target, :any, default: nil

  attr :position, :atom,
    default: :bottom_end,
    values: [:bottom_end, :bottom_start, :top_end, :top_start]

  attr :role, :string, default: "menu"
  attr :aria_orientation, :string, default: "vertical"

  attr :panel_label, :string,
    default: nil,
    doc: """
    Accessible name for the floating panel. Required when `role="dialog"`, since a
    dialog must have an accessible name and the trigger's `aria-label` (supplied via
    `@rest`) does not name the panel. Ignored for `role="menu"` panels, whose items
    provide their own labels.
    """

  attr :trigger_class, :string, default: nil

  attr :trigger_attrs, :list,
    default: [],
    doc: """
    Extra `{name, value}` attributes for the trigger button. Needed for
    `phx-value-*` pairs, which are not global attributes and so cannot arrive
    through `@rest`: a menu shared by several rows uses them to tell the
    toggle handler which row it belongs to.
    """

  attr :class, :string, default: nil

  attr :unstyled, :boolean,
    default: false,
    doc: """
    When `true`, the panel `<div>` receives only the caller-supplied `class` value —
    the default Tailwind positioning and animation utilities (`absolute`, `z-[100]`,
    `animate-in`, `fade-in`, `zoom-in`, `duration-200`) and the `position` shorthand
    classes are omitted. Use this from self-contained themes that supply their own
    positioning via theme CSS; the `phx-click-away` / Escape bindings remain active.
    """

  attr :rest, :global, include: ~w(aria-label)

  slot :trigger, required: true
  slot :panel, required: true

  @spec dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative"
      phx-click-away={@open && @on_close}
      phx-window-keydown={@open && @on_close}
      phx-key="escape"
      phx-target={@target}
    >
      <button
        type="button"
        class={@trigger_class}
        phx-click={@on_toggle}
        phx-target={@target}
        aria-expanded={to_string(@open)}
        aria-haspopup="true"
        aria-controls={"#{@id}-panel"}
        {@trigger_attrs}
        {@rest}
      >
        {render_slot(@trigger)}
      </button>
      <div
        :if={@open}
        id={"#{@id}-panel"}
        class={
          if @unstyled do
            @class
          else
            [
              "absolute z-[100] animate-in fade-in zoom-in duration-200",
              position_class(@position),
              @class
            ]
          end
        }
        role={@role}
        aria-orientation={@aria_orientation}
        aria-label={@panel_label}
      >
        {render_slot(@panel)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :danger, :boolean, default: false
  attr :rest, :global, include: ~w(navigate href patch method)

  @spec dropdown_item(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown_item(assigns) do
    ~H"""
    <%= if navigation_attrs?(@rest) do %>
      <.link
        class={["dropdown-item", @danger && "dropdown-item--danger"]}
        role="menuitem"
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="dropdown-item__icon" />
        {@label}
      </.link>
    <% else %>
      <button
        type="button"
        class={["dropdown-item", @danger && "dropdown-item--danger"]}
        role="menuitem"
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="dropdown-item__icon" />
        {@label}
      </button>
    <% end %>
    """
  end

  @spec dropdown_divider(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown_divider(assigns) do
    ~H"""
    <div class="dropdown-divider" role="separator"></div>
    """
  end

  defp navigation_attrs?(rest) do
    Map.has_key?(rest, :navigate) or Map.has_key?(rest, :href) or Map.has_key?(rest, :patch)
  end

  defp position_class(:bottom_end), do: "right-0 top-full mt-1"
  defp position_class(:bottom_start), do: "left-0 top-full mt-1"
  defp position_class(:top_end), do: "right-0 bottom-full mb-1"
  defp position_class(:top_start), do: "left-0 bottom-full mb-1"
end
