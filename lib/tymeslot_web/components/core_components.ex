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
    Buttons,
    Containers,
    Feedback,
    Flash,
    Forms,
    Icons,
    Layout,
    Modal,
    Navigation
  }

  # ========== LAYOUT ==========

  @doc """
  Main page layout wrapper with consistent structure.
  """
  slot :inner_block, required: true
  attr :show_steps, :boolean, default: false
  attr :current_step, :integer, default: 1
  attr :duration, :string, default: nil
  attr :username_context, :string, default: nil
  attr :theme_customization, :any, default: nil
  attr :has_custom_theme, :boolean, default: false
  @spec page_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def page_layout(assigns), do: Layout.page_layout(assigns)

  @doc """
  Global footer component.
  """
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
  attr :loading_text, :string, default: "Processing..."
  attr :variant, :atom, default: :primary
  attr :type, :string, default: "button"
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
  attr :level, :integer, default: 1
  attr :class, :string, default: ""
  slot :inner_block, required: true
  @spec section_header(map()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns), do: Containers.section_header(assigns)

  @doc """
  Renders an info/alert box.
  """
  attr :color_rgb, :string, default: "59, 130, 246"
  attr :variant, :atom, default: :info, values: [:info, :success, :warning, :error]
  slot :inner_block, required: true
  @spec info_box(map()) :: Phoenix.LiveView.Rendered.t()
  def info_box(assigns), do: Containers.info_box(assigns)

  # ========== FORM ELEMENTS ==========

  @doc """
  Renders a form field with label and error handling.
  """
  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: ""
  attr :required, :boolean, default: false
  attr :touched_fields, :list, default: []
  attr :rest, :global
  @spec form_field(map()) :: Phoenix.LiveView.Rendered.t()
  def form_field(assigns), do: Forms.form_field(assigns)

  @doc """
  Renders a textarea field with label and error handling.
  """
  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""
  attr :rows, :integer, default: 4
  attr :required, :boolean, default: false
  attr :touched_fields, :list, default: []
  attr :rest, :global
  @spec form_textarea(map()) :: Phoenix.LiveView.Rendered.t()
  def form_textarea(assigns), do: Forms.form_textarea(assigns)

  @doc """
  Renders a field error message.
  """
  attr :errors, :list, default: []
  attr :field, :atom, required: true
  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns), do: Forms.field_error(assigns)

  # ========== FEEDBACK ==========

  @doc """
  Renders a loading spinner.
  """
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
        <!-- Form content here -->
      </.modal>

      # Extra large modal for complex content
      <.modal id=\"details-modal\" show={@show_modal} size={:xlarge}>
        <:header>Meeting Details</:header>
        <!-- Detailed content here -->
      </.modal>

      # Full screen modal
      <.modal id=\"full-modal\" show={@show_modal} size={:full}>
        <:header>Full Screen View</:header>
        <!-- Full screen content here -->
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :size, :atom, default: :medium, values: [:small, :medium, :large, :xlarge, :full]
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
