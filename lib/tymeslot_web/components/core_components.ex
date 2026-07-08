defmodule TymeslotWeb.Components.CoreComponents do
  @moduledoc """
  Core UI components used throughout the application.
  This module is the stable entry point and delegates to smaller submodules.
  """
  use Phoenix.Component

  # Phoenix modules
  alias Phoenix.LiveView.JS

  # Application modules (alphabetical)
  alias TymeslotWeb.Components.CoreComponents.{
    Brand,
    Buttons,
    Containers,
    Dropdown,
    Feedback,
    Flash,
    Forms,
    Icons,
    Layout,
    Modal,
    Navigation
  }

  # ========== BRAND ==========

  @doc """
  Renders the Tymeslot logo.
  """
  attr :mode, :atom, default: :full, values: [:full, :icon]
  attr :class, :string, default: nil
  attr :img_class, :string, default: "h-10"
  @spec logo(map()) :: Phoenix.LiveView.Rendered.t()
  def logo(assigns), do: Brand.logo(assigns)

  # ========== LAYOUT ==========

  @doc """
  Main page layout wrapper with consistent structure.
  """
  slot :inner_block, required: true
  attr :show_steps, :boolean, default: false
  attr :current_step, :integer, default: 1
  attr :slug, :string, default: nil
  attr :username_context, :string, default: nil
  attr :theme_customization, :any, default: nil
  attr :has_custom_theme, :boolean, default: false
  @spec page_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def page_layout(assigns), do: Layout.page_layout(assigns)

  @doc """
  Global footer component.
  """
  attr :class, :string, default: nil
  @spec footer(map()) :: Phoenix.LiveView.Rendered.t()
  def footer(assigns), do: Layout.footer(assigns)

  # ========== BUTTONS ==========

  @doc """
  Renders an action button with gradient styling.

  ## Options
    * `:variant` - Button variant (:primary, :secondary, :danger). Defaults to :primary
    * `:type` - Button type attribute. Defaults to "button"
    * `:disabled` - Whether the button is disabled. Defaults to false
    * `:class` - Additional CSS classes
  """
  attr :variant, :atom, default: :primary
  attr :type, :string, default: "button"
  attr :form, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true
  @spec action_button(map()) :: Phoenix.LiveView.Rendered.t()
  def action_button(assigns), do: Buttons.action_button(assigns)

  @doc """
  Renders a loading button with spinner.

  ## Options
    * `:loading` - Whether to show loading state
    * `:loading_text` - Text to show when loading
    * `:variant` - Button variant (passed to action_button)
  """
  attr :loading, :boolean, default: false
  attr :loading_text, :string, default: nil
  attr :variant, :atom, default: :primary
  attr :type, :string, default: "button"
  attr :form, :string, default: nil
  attr :class, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true
  @spec loading_button(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_button(assigns), do: Buttons.loading_button(assigns)

  # ========== CARDS & CONTAINERS ==========

  @doc """
  Renders a glass-morphism card container.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true
  @spec glass_morphism_card(map()) :: Phoenix.LiveView.Rendered.t()
  def glass_morphism_card(assigns), do: Containers.glass_morphism_card(assigns)

  @doc """
  Renders a generic detail card with consistent styling.
  """
  attr :title, :string, default: nil
  slot :inner_block, required: true
  @spec detail_card(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_card(assigns), do: Containers.detail_card(assigns)

  @doc """
  Renders an icon badge with gradient background.
  """
  attr :color_from, :string, default: "#10b981"
  attr :color_to, :string, default: "#059669"
  attr :size, :atom, default: :medium, values: [:small, :medium, :large]
  slot :inner_block, required: true
  @spec icon_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_badge(assigns), do: Containers.icon_badge(assigns)

  @doc """
  Renders a section header with consistent styling.
  """
  attr :icon, :any,
    default: nil,
    doc: "A `hero-…` icon name (string) or a brand-mark atom (e.g. `:webhook`)"

  attr :title, :string, default: nil
  attr :count, :integer, default: nil
  attr :saving, :boolean, default: false
  attr :level, :integer, default: 1
  attr :title_class, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block
  @spec section_header(map()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns), do: Containers.section_header(assigns)

  @doc """
  Renders an info/alert box.
  """
  attr :variant, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :class, :string, default: ""
  slot :inner_block, required: true
  @spec info_box(map()) :: Phoenix.LiveView.Rendered.t()
  def info_box(assigns), do: Containers.info_box(assigns)

  # ========== FORM ELEMENTS ==========

  @doc """
  Renders a unified input field with label, icons, and error handling.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :checked, :boolean
  attr :prompt, :string, default: nil
  attr :options, :list
  attr :multiple, :boolean, default: false
  attr :required, :boolean, default: false
  attr :placeholder, :string, default: nil
  attr :rows, :integer, default: 4
  attr :icon, :string, default: nil
  attr :validate_on_blur, :boolean, default: false
  attr :class, :string, default: nil
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
  slot :description
  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  def input(assigns), do: Forms.input(assigns)

  @doc """
  Form wrapper with consistent styling and submission handling.
  """
  attr :for, :any, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(phx-change phx-submit phx-target)
  slot :inner_block, required: true
  @spec form_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def form_wrapper(assigns), do: Forms.form_wrapper(assigns)

  @doc """
  Renders a list of password requirements.
  """
  attr :class, :string, default: nil
  @spec password_requirements(map()) :: Phoenix.LiveView.Rendered.t()
  def password_requirements(assigns), do: Forms.password_requirements(assigns)

  @doc """
  Renders a field error message.
  """
  attr :errors, :list, default: []
  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns), do: Forms.field_error(assigns)

  # ========== FEEDBACK ==========

  @doc """
  Renders a loading spinner.
  """
  attr :class, :string, default: nil
  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns), do: Feedback.spinner(assigns)

  @doc """
  Renders an empty state display.
  """
  attr :message, :string, required: true
  attr :secondary_message, :string, default: nil
  slot :icon, required: true
  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns), do: Feedback.empty_state(assigns)

  # ========== NAVIGATION ==========

  @doc """
  Renders a detail row for definition lists.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  @spec detail_row(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_row(assigns), do: Navigation.detail_row(assigns)

  @doc """
  Renders a styled back link.
  """
  attr :to, :string, required: true
  slot :inner_block, required: true
  @spec back_link(map()) :: Phoenix.LiveView.Rendered.t()
  def back_link(assigns), do: Navigation.back_link(assigns)

  @doc """
  Renders a tabbed navigation interface.

  ## Usage

      <.tabs active_tab={@active_tab} target={@myself}>
        <:tab id="overview" label="Overview" icon="hero-home">
          <p>Overview content here</p>
        </:tab>
        <:tab id="settings" label="Settings" icon="hero-cog-6-tooth">
          <p>Settings content here</p>
        </:tab>
      </.tabs>
  """
  attr :active_tab, :string, required: true
  attr :target, :any, default: nil

  slot :tab, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string, doc: "Optional `hero-…` icon name"
  end

  @spec tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def tabs(assigns), do: Navigation.tabs(assigns)

  # ========== DROPDOWN ==========

  @doc """
  Standardised dropdown shell: a trigger button that reveals a floating panel.

  The component owns the `div.relative` wrapper, the `<button>` trigger, and the
  conditional panel. Callers manage open/close state via parent assigns and handle
  `on_toggle` / `on_close` events. Theme-specific visual styling passes through `class`.

  ## Attributes

    * `:id` - Required. DOM id on the outer container.
    * `:open` - Required. Whether the panel is visible.
    * `:on_toggle` - Required. Event name fired on trigger button click.
    * `:on_close` - Required. Event name fired by `phx-click-away` and Escape key when open.
    * `:target` - `phx-target` forwarded to the trigger button and the click-away handler.
    * `:position` - Panel placement: `:bottom_end` (default), `:bottom_start`, `:top_end`, `:top_start`.
    * `:role` - ARIA role on the panel `<div>`. Default `"menu"`. Pass `"dialog"` for panels that contain non-menuitem content such as inputs or checkboxes.
    * `:aria_orientation` - ARIA orientation on the panel. Default `"vertical"`.
    * `:trigger_class` - CSS classes on the trigger `<button>`.
    * `:class` - Additional CSS classes appended to the panel `<div>`.
    * `:unstyled` - When `true`, the panel receives only the caller-supplied `class` — the default Tailwind positioning/animation utilities and `position` shorthand are omitted. Use from self-contained themes that own their own positioning via theme CSS. Functional bindings (click-away, Escape) remain active. Default `false`.
    * `:aria-label` - Forwarded to the trigger button.

  ## Slots

    * `:trigger` - Required. Inner content of the trigger button.
    * `:panel` - Required. Content rendered inside the panel.
  """
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
    doc: "Accessible name for the panel; required when role is \"dialog\""

  attr :trigger_class, :string, default: nil
  attr :class, :string, default: nil
  attr :unstyled, :boolean, default: false
  attr :rest, :global, include: ~w(aria-label)
  slot :trigger, required: true
  slot :panel, required: true
  @spec dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown(assigns), do: Dropdown.dropdown(assigns)

  @doc "Standard clickable row inside a dropdown panel. Accepts `navigate`, `href`, `phx-click`, and all `phx-value-*` via `:global`."
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :danger, :boolean, default: false
  attr :rest, :global, include: ~w(navigate href patch method)
  @spec dropdown_item(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown_item(assigns), do: Dropdown.dropdown_item(assigns)

  @doc "Thin horizontal separator inside a dropdown panel."
  @spec dropdown_divider(map()) :: Phoenix.LiveView.Rendered.t()
  def dropdown_divider(assigns), do: Dropdown.dropdown_divider(assigns)

  # ========== FLASH MESSAGES ==========

  @doc """
  Renders a flash notice with modern glassmorphism styling.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} title="Success!">Operation completed successfully</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil, doc: "optional title for the flash message"
  attr :kind, :atom, values: [:info, :error, :warning], doc: "used for styling and flash lookup"
  attr :autoshow, :boolean, default: true, doc: "whether to auto show the flash on mount"
  attr :close, :boolean, default: true, doc: "whether the flash can be closed"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"
  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns), do: Flash.flash(assigns)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"
  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns), do: Flash.flash_group(assigns)

  # ========== MODAL ==========

  @doc """
  Renders a modal dialog with glassmorphism styling.

  ## Examples

      # Default medium size
      <.modal id=\"confirm-modal\" show={@show_modal}>
        <:header>Are you sure?</:header>
        This action cannot be undone.
        <:footer>
          <.action_button variant={:secondary} phx-click={JS.hide(to: \"#confirm-modal\")}>
            Cancel
          </.action_button>
          <.action_button variant={:danger} phx-click=\"delete\">\n            Delete\n          </.action_button>
        </:footer>
      </.modal>

      # Small modal
      <.modal id=\"small-modal\" show={@show_modal} size={:small}>
        <:header>Quick Note</:header>
        Your changes have been saved.
      </.modal>

      # Large modal for forms
      <.modal id=\"form-modal\" show={@show_modal} size={:large}>
        <:header>Edit Profile</:header>
        <%!-- Form content here --%>
      </.modal>

      # Extra large modal for complex content
      <.modal id=\"details-modal\" show={@show_modal} size={:xlarge}>
        <:header>Meeting Details</:header>
        <%!-- Detailed content here --%>
      </.modal>

      # Full screen modal
      <.modal id=\"full-modal\" show={@show_modal} size={:full}>
        <:header>Full Screen View</:header>
        <%!-- Full screen content here --%>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}

  attr :size, :atom,
    default: :medium,
    values: [:xsmall, :small, :medium, :large, :xlarge, :full]

  attr :aria_label, :string,
    default: nil,
    doc: "Accessible name for the dialog when no :header slot is rendered"

  slot :header, required: false
  slot :inner_block, required: true
  slot :footer, required: false
  @spec modal(map()) :: Phoenix.LiveView.Rendered.t()
  def modal(assigns), do: Modal.modal(assigns)

  # ========== ICONS ==========

  @doc """
  Renders a heroicon.

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `heroicons` library.

  ## Examples

      <.icon name=\"hero-x-mark-solid\" />
      <.icon name=\"hero-arrow-path\" class=\"ml-1 w-3 h-3 animate-spin\" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :style, :string, default: nil
  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(assigns), do: Icons.icon(assigns)
end
