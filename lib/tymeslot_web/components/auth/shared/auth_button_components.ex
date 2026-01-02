defmodule TymeslotWeb.Shared.Auth.ButtonComponents do
  @moduledoc """
  Button and link-style button components for authentication flows.
  """

  use TymeslotWeb, :html

  @spec auth_button(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_button(assigns) do
    assigns = assign_new(assigns, :type, fn -> "button" end)
    assigns = assign_new(assigns, :class, fn -> "" end)

    # Extract only valid HTML attributes
    rest_assigns =
      assigns
      |> Map.drop([:class, :type, :inner_block])
      |> Map.take([
        :id,
        :disabled,
        :form,
        :name,
        :value,
        :"phx-click",
        :"phx-submit",
        :"data-confirm",
        :"aria-label",
        :"aria-describedby"
      ])

    assigns = assign(assigns, :rest_assigns, rest_assigns)

    ~H"""
    <button
      type={@type}
      class={"w-full flex justify-center items-center py-2 sm:py-2.5 px-4 border border-transparent rounded-full shadow-sm text-sm sm:text-base font-semibold text-white bg-gradient-to-r from-purple-600 to-cyan-500 hover:from-purple-700 hover:to-cyan-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-purple-500 transition duration-300 ease-in-out transform hover:scale-[1.03] min-h-[2.5rem] sm:min-h-[2.75rem] btn-primary #{@class}"}
      {@rest_assigns}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @spec auth_link_button(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_link_button(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    # Extract only valid HTML attributes
    rest_assigns =
      assigns
      |> Map.drop([:href, :class, :inner_block])
      |> Map.take([
        :id,
        :target,
        :rel,
        :"phx-click",
        :"data-confirm",
        :"aria-label",
        :"aria-describedby"
      ])

    assigns = assign(assigns, :rest_assigns, rest_assigns)

    ~H"""
    <a
      href={@href}
      class={"flex items-center justify-center px-4 py-2.5 sm:py-2 border border-gray-300 rounded-md shadow-sm text-sm font-medium text-gray-700 bg-white hover:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-purple-500 transition-colors duration-300 min-h-[2.75rem] sm:min-h-[2.5rem] btn-secondary #{@class}"}
      {@rest_assigns}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  @spec simple_link_button(map()) :: Phoenix.LiveView.Rendered.t()
  def simple_link_button(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    # Extract only valid HTML attributes
    rest_assigns =
      assigns
      |> Map.drop([:href, :class, :inner_block])
      |> Map.take([
        :id,
        :target,
        :rel,
        :"phx-click",
        :"data-confirm",
        :"aria-label",
        :"aria-describedby"
      ])

    assigns = assign(assigns, :rest_assigns, rest_assigns)

    ~H"""
    <a
      href={@href}
      class={"w-full flex justify-center items-center py-2 sm:py-2.5 px-4 border border-transparent rounded-full shadow-sm text-sm sm:text-base font-semibold text-white bg-gradient-to-r from-purple-600 to-cyan-500 hover:from-purple-700 hover:to-cyan-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-purple-500 transition duration-300 ease-in-out transform hover:scale-[1.03] min-h-[2.5rem] sm:min-h-[2.75rem] btn-link #{@class}"}
      {@rest_assigns}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end
end
