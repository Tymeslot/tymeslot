defmodule TymeslotWeb.Dashboard.Calendar.RemoveGuestModal do
  @moduledoc """
  Asks before removing a guest from an event in the side panel, since
  removing emails them a cancellation. Remove sends
  `panel:guest_remove_confirm`; Cancel, Escape and a click outside send
  `panel:guest_remove_cancel`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :prompt, :map, required: true, doc: "`%{email: email}`"
  attr :target, :any, required: true

  @spec remove_guest_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def remove_guest_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id="calendar-remove-guest"
      show
      size={:small}
      icon="hero-user-minus"
      confirm_variant={:danger}
      title={dgettext("dashboard_calendar_editing", "Remove a guest")}
      on_cancel={JS.push("panel:guest_remove_cancel", target: @target)}
    >
      <p>{dgettext("dashboard_calendar_editing", "Remove %{email}?", email: @prompt.email)}</p>
      <p class="text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_editing",
          "They'll get an email saying they're no longer invited."
        )}
      </p>
      <:actions>
        <.action_button
          id="calendar-remove-guest-cancel"
          variant={:secondary}
          phx-click="panel:guest_remove_cancel"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Cancel")}
        </.action_button>
        <.action_button
          id="calendar-remove-guest-confirm"
          variant={:danger}
          phx-click="panel:guest_remove_confirm"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Remove")}
        </.action_button>
      </:actions>
    </Modal.confirm_modal>
    """
  end
end
