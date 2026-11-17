defmodule TymeslotWeb.Dashboard.Polls.ConfirmSlotModal do
  @moduledoc """
  Confirmation modal for settling an open poll on one of its times
  (`Polls.Confirm.confirm/3`).

  Stateless function component rendered by `PollsComponent`, which holds the
  slot being confirmed (or nil) and handles `close_confirm_slot_modal` and
  `confirm_slot`. Confirming closes the poll, books the meeting and emails
  everyone on the poll, none of which can be taken back, so it is never one
  click away.

  A time flagged as clashing with the host's calendar (`Polls.SlotHealth`) is
  not refused, since the host may well mean to drop the other event, but the
  dialog says so before they commit.

  `refusal/1` says how `PollsComponent` answers each reason
  `Polls.Confirm.confirm/3` refuses a confirmation with.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Polls.PollResults

  attr :poll, :map, default: nil
  attr :slot, :map, default: nil
  attr :time_format, :string, default: nil
  attr :conflict?, :boolean, default: false, doc: "whether the slot clashes with the calendar"
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
      <p :if={@conflict?} class="mt-2 font-semibold" data-testid="confirm-slot-conflict">
        {dgettext(
          "dashboard_polls",
          "This time clashes with an event on your calendar. Confirming books it anyway."
        )}
      </p>
    </.confirm_modal>
    """
  end

  @doc """
  How to answer `Polls.Confirm.confirm/3` refusing with `reason`: an inline
  error under the slot, a flash, the poll's having closed under a stale
  render, or a failure nobody expected, which is worth logging.
  """
  @spec refusal(term()) ::
          {:slot_error, String.t()}
          | {:flash, :error, String.t()}
          | :no_longer_open
          | {:unexpected, String.t()}
  def refusal(:slot_taken),
    do: {:slot_error, dgettext("dashboard_polls", "This time is no longer free")}

  def refusal(:time_off),
    do:
      {:slot_error,
       dgettext(
         "dashboard_polls",
         "This time falls within your time off. Change or remove the time off to confirm it."
       )}

  def refusal(:slot_in_past),
    do: {:slot_error, dgettext("dashboard_polls", "This time has already begun.")}

  # The host's own entry is not counted (`Confirm`), so a poll only they
  # answered has nobody to invite.
  def refusal(:no_participants),
    do:
      {:flash, :error,
       dgettext(
         "dashboard_polls",
         "Nobody but you has joined this poll yet, so there is nobody to invite."
       )}

  def refusal(reason) when reason in [:not_open, :not_found], do: :no_longer_open

  def refusal(_reason),
    do:
      {:unexpected, dgettext("dashboard_polls", "Couldn't confirm this time. Please try again.")}
end
