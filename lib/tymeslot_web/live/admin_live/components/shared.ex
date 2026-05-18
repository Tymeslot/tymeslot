defmodule TymeslotWeb.AdminLive.Components.Shared do
  @moduledoc """
  Small presentational helpers shared across the admin tabs.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec th(map()) :: Phoenix.LiveView.Rendered.t()
  def th(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "px-6 py-3 text-left text-xs font-black uppercase tracking-wider text-tymeslot-500",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end
end
