defmodule TymeslotWeb.StepNavigation do
  @moduledoc """
  Component for rendering step navigation indicators in the booking flow.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  attr :current_step, :integer, required: true
  attr :class, :string, default: ""
  attr :slug, :string, default: nil
  attr :username_context, :string, default: nil

  @spec step_indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def step_indicator(assigns) do
    ~H"""
    <div class={"step-indicator-container flex items-center space-x-3 sm:space-x-4 md:space-x-6 #{@class}"}>
      <.step_item
        step={1}
        current_step={@current_step}
        label={gettext("Duration")}
        clickable={@current_step > 1}
      />

      <div class={"step-connector " <> connector_class(1, @current_step)}></div>

      <.step_item
        step={2}
        current_step={@current_step}
        label={gettext("Date & Time")}
        clickable={@current_step > 2 && @slug != nil}
      />

      <div class={"step-connector " <> connector_class(2, @current_step)}></div>

      <.step_item
        step={3}
        current_step={@current_step}
        label={gettext("Details")}
        clickable={@current_step > 3 && @slug != nil}
      />

      <div class={"step-connector " <> connector_class(3, @current_step)}></div>

      <.step_item
        step={4}
        current_step={@current_step}
        label={gettext("Confirmation")}
        clickable={false}
      />
    </div>
    """
  end

  attr :step, :integer, required: true
  attr :current_step, :integer, required: true
  attr :label, :string, required: true
  attr :clickable, :boolean, default: false

  @spec step_item(map()) :: Phoenix.LiveView.Rendered.t()
  def step_item(assigns) do
    ~H"""
    <div class="step-item-wrapper flex flex-col items-center">
      <%= if @clickable do %>
        <button
          phx-click="navigate_to_step"
          phx-value-step={@step}
          class="flex flex-col items-center group"
        >
          <div class={"step-circle " <> step_class(@step, @current_step) <> " cursor-pointer hover:scale-125 transform transition-all"}>
            <span class="text-sm font-bold">{@step}</span>
          </div>
          <span class={"step-label " <> step_label_class(@step, @current_step) <> " mt-1 sm:mt-2 text-xs transition-colors"}>
            {@label}
          </span>
        </button>
      <% else %>
        <div class={"step-circle " <> step_class(@step, @current_step)}>
          <span class="text-sm font-bold">{@step}</span>
        </div>
        <span class={"step-label " <> step_label_class(@step, @current_step) <> " mt-1 sm:mt-2 text-xs"}>
          {@label}
        </span>
      <% end %>
    </div>
    """
  end

  defp step_class(step, current) when step <= current do
    "step-circle--active w-8 h-8 rounded-full bg-gradient-to-r from-purple-800 to-purple-900 text-white flex items-center justify-center shadow-lg border border-white/20 transition-all duration-300 scale-110"
  end

  defp step_class(_step, _current) do
    "w-8 h-8 rounded-full bg-tymeslot-700/90 text-white flex items-center justify-center border border-tymeslot-500/40 backdrop-blur-xs transition-all duration-300"
  end

  defp connector_class(step, current) when step < current do
    "step-connector--active w-4 sm:w-8 md:w-12 h-0.5 sm:h-1 bg-gradient-to-r from-purple-800 to-purple-900 rounded shadow-sm transition-all duration-500"
  end

  defp connector_class(_step, _current) do
    "w-4 sm:w-8 md:w-12 h-0.5 sm:h-1 bg-tymeslot-600/70 rounded transition-all duration-500"
  end

  defp step_label_class(step, current) when step == current do
    "text-white font-bold drop-shadow-md"
  end

  defp step_label_class(step, current) when step < current do
    "text-tymeslot-100 drop-shadow-md"
  end

  defp step_label_class(_step, _current) do
    "step-label--upcoming text-white/80 drop-shadow-md"
  end
end
