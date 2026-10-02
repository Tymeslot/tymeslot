defmodule TymeslotWeb.Components.CoreComponents.Page do
  @moduledoc "The page shell every dashboard section renders inside."
  use Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Containers

  @doc """
  Renders a dashboard section: one root with the shared vertical rhythm and
  bottom padding, and one header carrying the page's only `<h1>`.

      <.dashboard_page title={dgettext("dashboard_common", "Meeting Types")}
                       icon="hero-squares-2x2" saving={@saving}>
        <:actions><.action_button>Add Meeting Type</.action_button></:actions>
        ...
      </.dashboard_page>

  `title` is the section's sidebar label, under the same msgid, so the page
  and the navigation always name it alike. `saving` shows the saving
  indicator at the end of the header, beside any `:actions`; both wrap below
  the title on a narrow screen. Everything below the header is the inner
  block, and headings in it start at `<h2>`.

  A LiveComponent's root must be a single static tag, so a component renders
  this inside its own root element rather than as it.
  """
  attr :title, :string, required: true
  attr :icon, :any, default: nil, doc: "A `hero-…` icon name or a brand-mark atom"
  attr :saving, :boolean, default: false
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global
  slot :actions, doc: "Page-level controls at the end of the header"
  slot :inner_block, required: true

  @spec dashboard_page(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_page(assigns) do
    ~H"""
    <div class={["space-y-8 pb-20", @class]} {@rest}>
      <Containers.section_header level={1} icon={@icon} title={@title} saving={@saving}>
        <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
      </Containers.section_header>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
