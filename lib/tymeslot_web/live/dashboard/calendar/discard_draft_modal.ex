defmodule TymeslotWeb.Dashboard.Calendar.DiscardDraftModal do
  @moduledoc """
  Asks before the side panel's New event state is closed while its draft
  has guests, who have not been invited yet, as the old Quick Add did
  (`PanelNewDiscard`). Discard sends `panel:draft_discard_confirm`; the
  modal's own Go back, Escape and a click outside send
  `panel:draft_discard_cancel`.
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
      cancel_label={dgettext("dashboard_calendar_editing", "Go back")}
      confirm_label={dgettext("dashboard_calendar_editing", "Discard")}
      on_cancel={JS.push("panel:draft_discard_cancel", target: @target)}
      on_confirm={JS.push("panel:draft_discard_confirm", target: @target)}
      cancel_id="calendar-discard-draft-cancel"
      confirm_id="calendar-discard-draft-confirm"
    >
      <p>
        {dngettext(
          "dashboard_calendar_editing",
          "%{count} guest hasn't been invited yet. Discard?",
          "%{count} guests haven't been invited yet. Discard?",
          @prompt.count
        )}
      </p>
    </Modal.confirm_modal>
    """
  end
end
