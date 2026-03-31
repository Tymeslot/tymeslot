defmodule TymeslotWeb.Components.CoreComponents.Buttons do
  @moduledoc "Button components extracted from CoreComponents."
  use Phoenix.Component

  # Application modules
  alias TymeslotWeb.Components.CoreComponents.Feedback, as: Feedback

  # ========== BUTTONS ==========

  @doc """
  Renders an action button with gradient styling.

  ## Options
    * `:variant` - Button variant (:primary, :secondary, :danger, :outline). Defaults to :primary
    * `:type` - Button type attribute. Defaults to "button"
    * `:disabled` - Whether the button is disabled. Defaults to false
    * `:class` - Additional CSS classes
  """
  attr :variant, :atom,
    default: :primary,
    values: [:primary, :secondary, :danger, :outline],
    doc:
      "controls visual style: :primary (filled), :secondary (outlined), :danger (red), :outline (ghost/text-only)"

  attr :type, :string, default: "button"
  attr :form, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :rest, :global

  slot :inner_block, required: true

  @spec action_button(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def action_button(assigns) do
    ~H"""
    <button
      type={@type}
      form={@form}
      disabled={@disabled}
      class={["action-button", "action-button--#{@variant}", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

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
  attr :form, :string, default: nil
  attr :class, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  @spec loading_button(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def loading_button(assigns) do
    ~H"""
    <.action_button
      variant={@variant}
      type={@type}
      form={@form}
      disabled={@loading or @disabled}
      class={@class}
      {@rest}
    >
      <%= if @loading do %>
        <Feedback.spinner />
        <span>{@loading_text}</span>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </.action_button>
    """
  end
end
