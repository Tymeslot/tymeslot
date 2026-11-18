defmodule TymeslotWeb.Dashboard.Calendar.DiscardDraftModal do
  @moduledoc """
  Asks before the side panel's New event state is closed while its draft
  has guests, who have not been invited yet, as the old Quick Add did
  (`PanelNewDiscard`). Discard sends `panel:draft_discard_confirm`; Go
  back, Escape and a click outside send `panel:draft_discard_cancel`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :prompt, :map, required: true, doc: "`%{count: guests}`"
  attr :target, :any, required: true

  @spec discard_draft_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def discard_draft_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id="calendar-discard-draft"
      show
      size={:small}
      icon="hero-user-group"
      confirm_variant={:danger}
      title={dgettext("dashboard_calendar_editing", "Unsent invitations")}
      on_cancel={JS.push("panel:draft_discard_cancel", target: @target)}
    >
      <p>
        {dngettext(
          "dashboard_calendar_editing",
          "%{count} guest hasn't been invited yet. Discard?",
          "%{count} guests haven't been invited yet. Discard?",
          @prompt.count
        )}
      </p>
      <:actions>
        <.action_button
          id="calendar-discard-draft-cancel"
          variant={:secondary}
          phx-click="panel:draft_discard_cancel"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Go back")}
        </.action_button>
        <.action_button
          id="calendar-discard-draft-confirm"
          variant={:danger}
          phx-click="panel:draft_discard_confirm"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Discard")}
        </.action_button>
      </:actions>
    </Modal.confirm_modal>
    """
  end
end
