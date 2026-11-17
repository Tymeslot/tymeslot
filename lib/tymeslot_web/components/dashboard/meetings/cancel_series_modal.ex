defmodule TymeslotWeb.Components.Dashboard.Meetings.CancelSeriesModal do
  @moduledoc """
  Confirms cancelling every session of a series still to come, opened from
  the series modal's "Cancel remaining sessions".

  For a series the host was paid for, and can still refund, it offers the
  single cancel dialog's three refund choices
  (`CancelMeetingModal.refund_choices/1`), the full refund being the
  remaining sessions' share: one session's price for each, never more than
  is left to refund (`Tymeslot.BookingSeries.cancel_remaining/2`). For one
  it can no longer refund, it says why up front, as the single cancel
  dialog does (`CancelMeetingModal.no_refund_warning/1`).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :id, :string, required: true
  attr :show, :boolean, required: true

  attr :data, :map,
    default: nil,
    doc: "`%{overview: organizer_overview, form: refund form, error: refund errors}`"

  attr :target, :any, required: true

  @spec cancel_series_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_series_modal(assigns) do
    assigns =
      assign(
        assigns,
        :refundable?,
        assigns.data && MeetingPayments.refundable?(assigns.data.overview.payment)
      )

    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_booking_series", "Cancel remaining sessions")}
      confirm_label={dgettext("dashboard_booking_series", "Cancel sessions")}
      cancel_label={dgettext("dashboard_booking_series", "Keep sessions")}
      confirm_form="cancel-series-form"
      loading_label={dgettext("dashboard_booking_series", "Cancelling...")}
      on_cancel={JS.push("series:hide_cancel", target: @target)}
    >
      <form
        :if={@data}
        id="cancel-series-form"
        phx-submit="series:confirm_cancel"
        phx-target={@target}
        class="space-y-4"
        novalidate
      >
        <p>
          {dngettext(
            "dashboard_booking_series",
            "Cancel %{count} upcoming session with %{attendee}?",
            "Cancel %{count} upcoming sessions with %{attendee}?",
            @data.overview.upcoming,
            attendee: @data.overview.series.attendee_name
          )}
        </p>

        <CancelMeetingModal.refund_choices
          :if={@refundable?}
          booking_payment={@data.overview.payment}
          refund_error={@data.error}
          refund_form={@data.form}
          id_prefix="cancel-series"
        >
          <:full>
            <strong>
              {dgettext("dashboard_booking_series", "Refund the remaining sessions (%{amount}).",
                amount:
                  format_amount(
                    @data.overview.remaining_refund_cents,
                    @data.overview.payment.currency
                  )
              )}
            </strong>
            {dgettext(
              "dashboard_booking_series",
              "One session's share of the series payment for each session cancelled."
            )}
          </:full>
        </CancelMeetingModal.refund_choices>
        <CancelMeetingModal.no_refund_warning booking_payment={@data.overview.payment} />

        <p class="text-tymeslot-500">
          {dgettext(
            "dashboard_booking_series",
            "This action cannot be undone. The attendee is sent one email listing every cancelled session. Sessions that already took place stay as they are."
          )}
        </p>
      </form>
    </Modal.confirm_modal>
    """
  end
end
