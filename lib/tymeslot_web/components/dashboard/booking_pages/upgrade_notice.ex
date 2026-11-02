defmodule TymeslotWeb.Components.Dashboard.BookingPages.UpgradeNotice do
  @moduledoc """
  What the dashboard shows where booking pages need a plan the host does not
  have: a short explanation, then the upgrade prompt a deployment registers as
  `:feature_placeholder_components[:booking_pages]`. Without one registered,
  as on a self-hosted install whose checker refuses the feature, the
  explanation stands alone.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :id, :string, required: true
  attr :current_user, :any, required: true
  attr :placeholder_components, :any, default: nil, doc: "a map or keyword list"
  slot :inner_block, required: true, doc: "the explanation"

  @spec upgrade_notice(map()) :: Phoenix.LiveView.Rendered.t()
  def upgrade_notice(assigns) do
    assigns = assign(assigns, :prompt, prompt(assigns.placeholder_components))

    ~H"""
    <div id={@id} data-testid="booking-pages-locked">
      <.info_box variant={:warning}>
        <div class="flex items-start gap-3">
          <.icon name="hero-lock-closed" class="w-5 h-5 shrink-0 mt-0.5" />
          <p>{render_slot(@inner_block)}</p>
        </div>
      </.info_box>
      <.live_component
        :if={@prompt}
        module={@prompt}
        id={"#{@id}-prompt"}
        feature={:booking_pages}
        current_user={@current_user}
      />
    </div>
    """
  end

  # Bracket access reads a keyword list and a map alike.
  defp prompt(nil), do: nil
  defp prompt(components), do: components[:booking_pages]
end
