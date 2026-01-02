defmodule TymeslotWeb.StepNavigation do
  @moduledoc """
  Component for rendering step navigation indicators in the booking flow.
  """

  use Phoenix.Component

  attr :current_step, :integer, required: true
  attr :class, :string, default: ""
  attr :duration, :string, default: nil
  attr :username_context, :string, default: nil

  @spec step_indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def step_indicator(assigns) do
    ~H"""
    <div class={"flex items-center space-x-3 sm:space-x-4 md:space-x-6 #{@class}"}>
      <.step_item
        step={1}
        current_step={@current_step}
        label="Duration"
        path={get_step_path(@username_context, 1)}
        clickable={@current_step > 1}
      />

      <div class={connector_class(1, @current_step)}></div>

      <.step_item
        step={2}
        current_step={@current_step}
        label="Date & Time"
        path={if @duration && @current_step > 2, do: get_step_path(@username_context, 2, @duration), else: nil}
        clickable={@current_step > 2 && @duration != nil}
      />

      <div class={connector_class(2, @current_step)}></div>

      <.step_item
        step={3}
        current_step={@current_step}
        label="Details"
        path={if @duration && @current_step > 3, do: get_step_path(@username_context, 3, @duration), else: nil}
        clickable={@current_step > 3 && @duration != nil}
      />

      <div class={connector_class(3, @current_step)}></div>

      <.step_item
        step={4}
        current_step={@current_step}
        label="Confirmation"
        path=""
        clickable={false}
      />
    </div>
    """
  end

  attr :step, :integer, required: true
  attr :current_step, :integer, required: true
  attr :label, :string, required: true
  attr :path, :string, default: nil
  attr :clickable, :boolean, default: false

  @spec step_item(map()) :: Phoenix.LiveView.Rendered.t()
  def step_item(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <%= if @clickable && @path do %>
        <button
          phx-click="navigate_to_step"
          phx-value-step={@step}
          class="flex flex-col items-center group"
        >
          <div class={step_class(@step, @current_step) <> " cursor-pointer hover:scale-125 transform transition-all"}>
            <span class="text-sm font-bold">{@step}</span>
          </div>
          <span class={step_label_class(@step, @current_step) <> " mt-1 sm:mt-2 text-xs group-hover:text-purple-200 transition-colors"}>
            {@label}
          </span>
        </button>
      <% else %>
        <div class={step_class(@step, @current_step)}>
          <span class="text-sm font-bold">{@step}</span>
        </div>
        <span class={step_label_class(@step, @current_step) <> " mt-1 sm:mt-2 text-xs"}>
          {@label}
        </span>
      <% end %>
    </div>
    """
  end

  defp step_class(step, current) when step <= current do
    "w-8 h-8 rounded-full bg-gradient-to-r from-purple-800 to-purple-900 text-white flex items-center justify-center shadow-lg border border-white/20 transition-all duration-300 scale-110"
  end

  defp step_class(_, _) do
    "w-8 h-8 rounded-full bg-gray-700/90 text-white flex items-center justify-center border border-gray-500/40 backdrop-blur-sm transition-all duration-300"
  end

  defp connector_class(step, current) when step < current do
    "w-4 sm:w-8 md:w-12 h-0.5 sm:h-1 bg-gradient-to-r from-purple-800 to-purple-900 rounded shadow-sm transition-all duration-500"
  end

  defp connector_class(_, _) do
    "w-4 sm:w-8 md:w-12 h-0.5 sm:h-1 bg-gray-600/70 rounded transition-all duration-500"
  end

  defp step_label_class(step, current) when step == current do
    "text-white font-bold drop-shadow-md"
  end

  defp step_label_class(step, current) when step < current do
    "text-gray-200 drop-shadow-md"
  end

  defp step_label_class(_, _) do
    "text-gray-300 drop-shadow-md"
  end

  defp get_step_path(username_context, step, duration \\ nil)

  defp get_step_path(username_context, 1, _duration) do
    if username_context, do: "/#{username_context}", else: "/"
  end

  defp get_step_path(username_context, 2, duration) when is_binary(duration) do
    if username_context do
      "/#{username_context}/schedule/#{duration}"
    else
      nil
    end
  end

  defp get_step_path(_username_context, 2, _duration), do: nil

  defp get_step_path(username_context, 3, duration) when is_binary(duration) do
    if username_context do
      "/#{username_context}/schedule/#{duration}/book"
    else
      nil
    end
  end

  defp get_step_path(_username_context, 3, _duration), do: nil
end
