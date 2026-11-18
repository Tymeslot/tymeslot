defmodule TymeslotWeb.Dashboard.Calendar.BadgeStrings do
  @moduledoc """
  What the grid's event badges are drawn with (`calendar/render.js`,
  `render_month.js`), merged into `ClientStrings.build/1`: the seat lock's
  explanation, and the badges' icons under `icons`, rendered here by
  `<.icon>` so the hook draws the same inline SVG as every template and
  holds no artwork of its own.
  """

  use TymeslotWeb, :html

  alias Phoenix.HTML.Safe
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @icons %{lock: "hero-lock-closed-micro", guests: "hero-user-micro"}

  @doc "The strings map, in the current Gettext locale."
  @spec strings() :: map()
  def strings do
    %{
      seat_locked: CalendarEditMessages.seat_lock_message(),
      icons: Map.new(@icons, fn {key, name} -> {key, icon_html(name)} end)
    }
  end

  defp icon_html(name) do
    assigns = %{name: name}

    ~H"""
    <.icon name={@name} class="cal-ev-badge-icon" />
    """
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> String.trim()
  end
end
