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
        :"phx-value-state",
        :"data-confirm",
        :"aria-label",
        :"aria-describedby"
      ])

    assigns = assign(assigns, :rest_assigns, rest_assigns)

    ~H"""
    <button
      type={@type}
      class={["btn-primary w-full py-3.5 text-base", @class]}
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
      class={["btn-secondary flex-1 py-3.5 text-sm", @class]}
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
      class={["btn-primary w-full py-3.5 text-sm", @class]}
      {@rest_assigns}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end
end
