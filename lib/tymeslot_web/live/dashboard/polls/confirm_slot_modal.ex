defmodule TymeslotWeb.Dashboard.Polls.ConfirmSlotModal do
  @moduledoc """
  Confirmation modal for settling an open poll on one of its times
  (`Polls.Confirm.confirm/3`).

  Stateless function component rendered by `PollsComponent`, which holds the
  slot being confirmed (or nil) and handles `close_confirm_slot_modal` and
  `confirm_slot`. Confirming closes the poll, books the meeting and emails
  everyone on the poll, none of which can be taken back, so it is never one
  click away.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Polls.PollResults

  attr :poll, :map, default: nil
  attr :slot, :map, default: nil
  attr :time_format, :string, default: nil
  attr :myself, :any, required: true

  @spec confirm_slot_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_slot_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@poll && @slot}
      id="confirm-slot-modal"
      show
      title={dgettext("dashboard_polls", "Confirm this time?")}
      confirm_label={dgettext("dashboard_polls", "Confirm this time")}
      cancel_label={dgettext("dashboard_polls", "Not yet")}
      on_cancel={JS.push("close_confirm_slot_modal", target: @myself)}
      on_confirm={JS.push("confirm_slot", value: %{slot: @slot.id}, target: @myself)}
      data-testid="confirm-slot"
    >
      <p>
        {dgettext(
          "dashboard_polls",
          "“%{title}” will be confirmed for %{time} (%{timezone}) and voting will close.",
          title: @poll.title,
          time: PollResults.format_slot(@slot, @poll.timezone, @time_format),
          timezone: @poll.timezone
        )}
      </p>
      <p class="mt-2">
        {dgettext(
          "dashboard_polls",
          "Everyone on the poll will be emailed the meeting."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
