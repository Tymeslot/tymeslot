defmodule TymeslotWeb.OnboardingLive.StagePreviewModal do
  @moduledoc """
  The stage's preview at full size, for screens below `lg`.

  On a phone the stage is a short card above the questions, so its Expand
  button opens this modal, which shows the same page scaled to the width of
  the screen. The parent LiveView owns the `show` state (`ModalHook`, as
  `:stage_preview`) and the `expand_stage` and `close_stage_preview` events.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [modal: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.OnboardingLive.StageFrame

  @doc """
  Renders the expanded stage preview. Its content renders only while the
  modal is open, so the page is not drawn twice for nothing.
  """
  attr :show, :boolean, required: true
  attr :canvas, :string, default: nil, doc: "the theme's canvas colour, behind the page"
  slot :inner_block, required: true

  @spec stage_preview_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def stage_preview_modal(assigns) do
    ~H"""
    <.modal
      id="onboarding-stage-preview"
      show={@show}
      size={:full}
      on_cancel={JS.push("close_stage_preview")}
    >
      <:header>{dgettext("onboarding_wizard", "Your booking page")}</:header>
      <div
        :if={@show}
        class="stage-preview-canvas"
        style={@canvas && "--stage-canvas: #{@canvas};"}
        aria-hidden="true"
      >
        <StageFrame.scaled id="onboarding-stage-preview-scale">
          {render_slot(@inner_block)}
        </StageFrame.scaled>
      </div>
    </.modal>
    """
  end
end
