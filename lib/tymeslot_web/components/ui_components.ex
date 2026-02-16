defmodule TymeslotWeb.Components.UIComponents do
  @moduledoc """
  Reusable UI components for the Tymeslot application.
  These components encapsulate common UI patterns used across LiveViews.
  """
  use Phoenix.Component
  alias TymeslotWeb.Components.CoreComponents.Forms

  @doc """
  Renders a glass-morphism card container.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec glass_morphism_card(map()) :: Phoenix.LiveView.Rendered.t()
  def glass_morphism_card(assigns) do
    ~H"""
    <div class={"glass-morphism-card #{@class}"}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a meeting details card with consistent styling.
  """
  attr :title, :string, default: nil
  slot :inner_block, required: true

  @spec meeting_details_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_details_card(assigns) do
    ~H"""
    <div class="meeting-details-card">
      <%= if @title && @title != "" do %>
        <h3 class="text-xl font-black text-slate-900 tracking-tight mb-4">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an action button with gradient styling.

  ## Options
    * `:variant` - Button variant (:primary, :secondary, :danger). Defaults to :primary
    * `:type` - Button type attribute. Defaults to "button"
    * `:disabled` - Whether the button is disabled. Defaults to false
    * `:class` - Additional CSS classes
  """
  attr :variant, :atom, default: :primary, values: [:primary, :secondary, :danger, :outline]
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :rest, :global

  slot :inner_block, required: true

  @spec action_button(map()) :: Phoenix.LiveView.Rendered.t()
  def action_button(assigns) do
    ~H"""
    <button
      type={@type}
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
  attr :variant, :atom, default: :primary, values: [:primary, :secondary, :danger, :outline]
  attr :type, :string, default: "button"
  attr :class, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  @spec loading_button(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_button(assigns) do
    ~H"""
    <.action_button
      variant={@variant}
      type={@type}
      disabled={@loading or @disabled}
      class={@class}
      {@rest}
    >
      <%= if @loading do %>
        <.spinner />
        <span>{@loading_text}</span>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </.action_button>
    """
  end

  @doc """
  Renders a loading spinner.
  """
  # No assigns used in this component - purely static HTML
  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg class="spinner" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  @doc """
  Renders a field error message.
  """
  attr :errors, :list, default: []
  attr :field, :atom, required: true

  @spec field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def field_error(assigns) do
    ~H"""
    <%= if Enum.any?(@errors) do %>
      <div class="field-error">
        {Enum.join(@errors, ", ")}
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a time slot button.
  """
  attr :slot, :map, required: true
  attr :selected, :boolean, default: false
  attr :rest, :global

  @spec time_slot_button(map()) :: Phoenix.LiveView.Rendered.t()
  def time_slot_button(assigns) do
    ~H"""
    <button
      class={[
        "time-slot-button",
        @selected && "time-slot-button--selected"
      ]}
      {@rest}
    >
      {Calendar.strftime(@slot.start_time, "%-I:%M %p")}
    </button>
    """
  end

  @doc """
  Renders a calendar day cell.
  """
  attr :day, :map, required: true
  attr :selected, :boolean, default: false
  attr :available, :boolean, default: true
  attr :current_month, :boolean, default: true
  attr :rest, :global

  @spec calendar_day(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_day(assigns) do
    ~H"""
    <button
      class={[
        "calendar-day",
        @selected && "calendar-day--selected",
        !@available && "calendar-day--unavailable",
        !@current_month && "calendar-day--other-month",
        (@day.today || @day.is_today) && "calendar-day--today",
        Map.get(@day, :past, false) && "calendar-day--past"
      ]}
      disabled={!@available || !@current_month}
      {@rest}
    >
      <span class="calendar-day__number">{@day.day}</span>
    </button>
    """
  end

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
  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  def input(assigns), do: Forms.input(assigns)
end
