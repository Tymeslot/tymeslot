defmodule TymeslotWeb.Themes.Shared.Journey.Components do
  @moduledoc """
  Markup the navigators showing several moments need around and inside them.

    * `frame/1`: `SchedulingPage` renders the visible moments inside it. A
      navigator with `frame/0` names the element (`Navigators.Continuous` a
      `div`, `Navigators.Transcript` an ordered list that is a polite live
      region); for one without (`Navigators.Paged`) the moment is rendered
      bare, so a paged theme's DOM is what it was.
    * `moment_heading/1`: the heading a moment opens with. It can take the
      keyboard focus (`tabindex="-1"`), and takes it, scrolling the moment
      into view, when its moment has just become current through the
      visitor's own action (the runtime's `:journey_focus`); never on page
      load. Its id carries the moment's state, so a moment that becomes
      current again mounts a new heading and takes the focus again.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :navigator, :atom, required: true
  slot :inner_block, required: true

  @spec frame(map()) :: Phoenix.LiveView.Rendered.t()
  def frame(assigns) do
    case frame_of(assigns.navigator) do
      {tag, attrs} -> framed(assign(assigns, tag: tag, attrs: attrs))
      nil -> bare(assigns)
    end
  end

  attr :moment, :atom, required: true
  attr :moment_state, :atom, required: true, values: [:current, :done, :open]
  attr :focus, :atom, default: nil, doc: "the `:journey_focus` assign"
  attr :tag, :string, default: "h2", values: ~w(h1 h2 h3 h4)
  attr :rest, :global
  slot :inner_block, required: true

  @spec moment_heading(map()) :: Phoenix.LiveView.Rendered.t()
  def moment_heading(assigns) do
    assigns =
      assign(
        assigns,
        :take_focus,
        assigns.focus == assigns.moment and assigns.moment_state == :current
      )

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={"#{@moment}-heading-#{@moment_state}"}
      tabindex="-1"
      phx-mounted={@take_focus && JS.focus()}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  defp framed(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag} {@attrs}>{render_slot(@inner_block)}</.dynamic_tag>
    """
  end

  defp bare(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  defp frame_of(navigator) do
    if Code.ensure_loaded?(navigator) and function_exported?(navigator, :frame, 0),
      do: navigator.frame()
  end
end
