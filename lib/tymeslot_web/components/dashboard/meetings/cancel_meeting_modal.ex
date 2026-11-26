defmodule TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal do
  @moduledoc """
  Modal component for confirming meeting cancellation.

  When the meeting has an associated paid `booking_payment`, the modal
  shows three refund options: full refund, partial refund, or cancel
  without refunding (gated behind a confirmation tickbox). A group session
  with paid seats (`seat_payments`) offers two instead: refund everyone in
  full, or no one (behind the same tickbox); a partial refund is made per
  payment, from the payments page. For free bookings the modal preserves
  the original confirm-or-keep flow.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Components.CoreComponents, only: [info_box: 1]

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.Meetings.HostManaged
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2, format_totals: 1]

  @doc """
  Renders a cancel meeting confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `meeting` - The meeting to be cancelled (required)
    * `timezone` - The timezone to display times in (optional, defaults to UTC)
    * `cancelling` - Boolean indicating if cancellation is in progress (required)
    * `on_cancel` - JS command to execute when cancelling (required)
    * `confirm_event` - Event name pushed when the form is submitted (required)
    * `target` - phx-target reference for the confirm event (required)
    * `booking_payment` - Optional booking_payment record. When set and
      refundable, the modal exposes refund options.
    * `seat_payments` - A group session's paid seats still owed money
      (`BookingPayments.seat_payments_for_meeting/2`). When any, the modal
      offers to refund everyone or no one.
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "24h"
  attr :cancelling, :boolean, required: true
  attr :on_cancel, JS, required: true
  attr :confirm_event, :string, required: true
  attr :target, :any, required: true
  attr :booking_payment, :map, default: nil
  attr :seat_payments, :list, default: []

  attr :refund_error, :map,
    default: %{},
    doc: "`:amount`, `:acknowledgement` and `:payments` (the paid seats changed) messages"

  attr :refund_form, :map, default: %{choice: "full", amount: "", acknowledged: false}

  @spec cancel_meeting_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_meeting_modal(assigns) do
    assigns =
      assign(assigns,
        paid?: MeetingPayments.refundable?(assigns[:booking_payment]),
        seats_paid?: assigns.seat_payments != []
      )

    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_bookings_cancel", "Cancel meeting")}
      confirm_label={
        if @paid? or @seats_paid?,
          do: dgettext("dashboard_bookings_cancel", "Confirm cancellation"),
          else: dgettext("dashboard_bookings_cancel", "Cancel Meeting")
      }
      cancel_label={dgettext("dashboard_bookings_cancel", "Keep Meeting")}
      confirm_form="cancel-meeting-form"
      loading={@cancelling}
      loading_label={dgettext("dashboard_bookings_cancel", "Cancelling...")}
      on_cancel={@on_cancel}
    >
      <form
        :if={@meeting}
        id="cancel-meeting-form"
        phx-submit={@confirm_event}
        phx-target={@target}
        class="space-y-4"
        novalidate
      >
        <p>
          {confirm_question(@meeting, @timezone, @time_format)}
        </p>

        <p
          :if={@refund_error[:payments]}
          id="cancel-refund-payments-error"
          class="form-error"
          role="alert"
        >
          {@refund_error[:payments]}
        </p>

        <.refund_choices
          :if={@paid?}
          booking_payment={@booking_payment}
          refund_error={@refund_error}
          refund_form={@refund_form}
        >
          <:full :if={is_binary(@booking_payment.series_id)}>
            <strong>{dgettext("dashboard_bookings_cancel", "Refund this session.")}</strong>
            {dgettext(
              "dashboard_bookings_cancel",
              "Refunds one session's share of the series payment (%{amount}).",
              amount:
                format_amount(
                  MeetingPayments.default_cancellation_refund_cents(@booking_payment),
                  @booking_payment.currency
                )
            )}
          </:full>
          <:full :if={!is_binary(@booking_payment.series_id)}>
            <strong>{dgettext("dashboard_bookings_cancel", "Full refund.")}</strong>
            {dgettext("dashboard_bookings_cancel", "Refunds the remaining balance (%{amount}).",
              amount: format_amount(refundable_remaining(@booking_payment), @booking_payment.currency)
            )}
          </:full>
        </.refund_choices>
        <.seat_options
          :if={@seats_paid?}
          seat_payments={@seat_payments}
          refund_error={@refund_error}
          refund_form={@refund_form}
        />
        <.no_refund_warning booking_payment={@booking_payment} />
        <p
          :if={pending_refund(@booking_payment) > 0}
          id="cancel-meeting-pending-refund"
          class="text-token-sm text-tymeslot-700"
        >
          {dgettext("dashboard_bookings_cancel", "A refund of %{amount} is already being processed.",
            amount: format_amount(pending_refund(@booking_payment), @booking_payment.currency)
          )}
        </p>
        <p :if={not @paid? and not @seats_paid?} class="text-tymeslot-500">
          {if Helpers.group_meeting?(@meeting),
            do:
              dgettext(
                "dashboard_bookings_cancel",
                "This action cannot be undone. Every participant will be notified of the cancellation."
              ),
            else:
              dgettext(
                "dashboard_bookings_cancel",
                "This action cannot be undone. The attendee will be notified of the cancellation."
              )}
        </p>
      </form>
    </Modal.confirm_modal>
    """
  end

  # A group meeting has no single attendee to name: it is with however many
  # people currently hold a seat on it. Nor has a meeting the host manages:
  # the one in its attendee fields is only the first of its guests, so it is
  # named by its title, as its card is.
  defp confirm_question(meeting, timezone, time_format) do
    scheduled_for =
      "#{Helpers.format_meeting_date(meeting, timezone)} • #{Helpers.format_meeting_time(meeting, timezone, time_format)}"

    cond do
      Helpers.group_meeting?(meeting) ->
        count = length(Helpers.participants(meeting))

        dngettext(
          "dashboard_bookings_cancel",
          "Are you sure you want to cancel this group meeting with %{count} participant scheduled for %{when}?",
          "Are you sure you want to cancel this group meeting with %{count} participants scheduled for %{when}?",
          count,
          when: scheduled_for
        )

      HostManaged.managed?(meeting) ->
        dgettext(
          "dashboard_bookings_cancel",
          "Are you sure you want to cancel “%{title}” scheduled for %{when}? Every guest is told.",
          title: meeting.title,
          when: scheduled_for
        )

      true ->
        dgettext(
          "dashboard_bookings_cancel",
          "Are you sure you want to cancel the meeting with %{name} scheduled for %{when}?",
          name: meeting.attendee_name,
          when: scheduled_for
        )
    end
  end

  attr :booking_payment, :map, required: true
  attr :refund_error, :map, default: %{}
  attr :refund_form, :map, required: true
  attr :id_prefix, :string, default: "cancel", doc: "prefixes the acknowledgement error's id"
  slot :full, required: true, doc: "what the full refund option says it refunds"

  @doc """
  The refund a host chooses when cancelling something paid for: the full
  refund (worded by the `:full` slot), a partial amount, or none at all
  behind an acknowledgement. Posts `cancel_refund_choice`,
  `cancel_refund_amount` and `cancel_refund_no_refund_ack`. Shared by the
  single cancel dialog and the cancel-remaining dialog of a series.
  """
  @spec refund_choices(map()) :: Phoenix.LiveView.Rendered.t()
  def refund_choices(assigns) do
    assigns = assign(assigns, :remaining, refundable_remaining(assigns.booking_payment))

    ~H"""
    <div class="rounded-token-md border border-tymeslot-200 bg-tymeslot-50 p-3 text-token-sm">
      <fieldset class="space-y-2">
        <legend class="mb-3">
          {dgettext(
            "dashboard_bookings_cancel",
            "This booking was paid. Choose how to handle the refund - the attendee always receives the full amount you refund."
          )}
        </legend>

        <label class="flex items-start gap-2">
          <Forms.input
            type="radio"
            name="cancel_refund_choice"
            value="full"
            checked={@refund_form.choice == "full"}
          />
          <span>{render_slot(@full)}</span>
        </label>

        <label class="flex items-start gap-2">
          <Forms.input
            type="radio"
            name="cancel_refund_choice"
            value="partial"
            checked={@refund_form.choice == "partial"}
          />
          <span>
            <strong>{dgettext("dashboard_bookings_cancel", "Partial refund.")}</strong>
            {dgettext("dashboard_bookings_cancel", "Refund only part of the booking amount.")}
          </span>
        </label>

        <div class="ml-6">
          <Forms.input
            type="number"
            name="cancel_refund_amount"
            label={dgettext("dashboard_bookings_cancel", "Partial amount")}
            min="0.01"
            max={Money.to_major_string(@remaining, @booking_payment.currency)}
            step="0.01"
            placeholder={"0.00 #{String.upcase(@booking_payment.currency)}"}
            value={@refund_form.amount}
            errors={List.wrap(@refund_error[:amount])}
          />
        </div>

        <.no_refund_choice
          id_prefix={@id_prefix}
          refund_form={@refund_form}
          refund_error={@refund_error}
          label={dgettext("dashboard_bookings_cancel", "Cancel without refund.")}
          detail={
            dgettext(
              "dashboard_bookings_cancel",
              "The attendee keeps no money. Use only if the attendee already agreed."
            )
          }
          acknowledgement={
            dgettext(
              "dashboard_bookings_cancel",
              "I understand the attendee will not receive a refund."
            )
          }
        />
      </fieldset>
    </div>
    """
  end

  attr :seat_payments, :list, required: true
  attr :refund_error, :map, default: %{}
  attr :refund_form, :map, required: true

  # A group session's refund: every paid seat in full, or none behind an
  # acknowledgement. Posts the same fields as `refund_choices/1`, less the
  # amount: a partial refund is a per-payment action.
  #
  # Seats paid more than 60 days ago are past the refund window, so neither
  # choice refunds them: a warning says so, and that Stripe can.
  defp seat_options(assigns) do
    summary = BookingPayments.seat_money_summary(assigns.seat_payments)
    outside_window = BookingPayments.seat_money(assigns.seat_payments).outside_window

    assigns =
      assign(assigns,
        count: summary.count,
        total: format_totals(summary.totals),
        outside_window_count: outside_window.count,
        outside_window_total: format_totals(outside_window.totals)
      )

    ~H"""
    <div class="rounded-token-md border border-tymeslot-200 bg-tymeslot-50 p-3 text-token-sm">
      <fieldset class="space-y-2">
        <legend class="mb-3">
          {dngettext(
            "dashboard_bookings_cancel",
            "%{count} participant paid for this session (%{amount} still held).",
            "%{count} participants paid for this session (%{amount} still held).",
            @count,
            amount: @total
          )}
        </legend>

        <label class="flex items-start gap-2">
          <Forms.input
            type="radio"
            name="cancel_refund_choice"
            value="full"
            checked={@refund_form.choice != "none"}
          />
          <span>
            <strong>{dgettext("dashboard_bookings_cancel", "Refund everyone in full.")}</strong>
            {dgettext(
              "dashboard_bookings_cancel",
              "Each participant gets back what they paid, and an email once their refund is issued."
            )}
          </span>
        </label>

        <.no_refund_choice
          id_prefix="cancel"
          refund_form={@refund_form}
          refund_error={@refund_error}
          label={dgettext("dashboard_bookings_cancel", "Don't refund anyone.")}
          detail={
            dgettext(
              "dashboard_bookings_cancel",
              "Each participant's payment stays with you until you refund it from Payments."
            )
          }
          acknowledgement={
            dgettext(
              "dashboard_bookings_cancel",
              "I understand the participants get nothing back unless I refund them later from Payments."
            )
          }
        />
      </fieldset>
    </div>
    <.info_box :if={@outside_window_count > 0} variant={:warning} class="mb-0!">
      {dngettext(
        "dashboard_bookings_cancel",
        "Cancelling won't refund %{count} participant (%{amount}): their payment is older than the 60-day refund window. You can refund it from Stripe.",
        "Cancelling won't refund %{count} participants (%{amount}): their payments are older than the 60-day refund window. You can refund them from Stripe.",
        @outside_window_count,
        amount: @outside_window_total
      )}
    </.info_box>
    """
  end

  attr :id_prefix, :string, required: true, doc: "prefixes the acknowledgement error's id"
  attr :refund_form, :map, required: true
  attr :refund_error, :map, required: true
  attr :label, :string, required: true, doc: "the option's name, in bold"
  attr :detail, :string, required: true, doc: "what refunding no one means for the payer"
  attr :acknowledgement, :string, required: true, doc: "what ticking the box agrees to"

  # Cancelling without refunding: the `none` radio and the acknowledgement it
  # needs, whose error the checkbox is described by. Shared by
  # `refund_choices/1` and `seat_options/1`, which word it for one attendee
  # or for every participant.
  defp no_refund_choice(assigns) do
    assigns = assign(assigns, :error_id, "#{assigns.id_prefix}-refund-ack-error")

    ~H"""
    <label class="flex items-start gap-2">
      <Forms.input
        type="radio"
        name="cancel_refund_choice"
        value="none"
        checked={@refund_form.choice == "none"}
      />
      <span>
        <strong>{@label}</strong>
        {@detail}
      </span>
    </label>

    <label class="flex items-start gap-2 ml-6">
      <%!-- raw-input: acknowledgement checkbox inside its inline label beside the text; <.input> would nest block wrappers inside the label --%>
      <input
        type="checkbox"
        name="cancel_refund_no_refund_ack"
        value="true"
        checked={@refund_form.acknowledged}
        aria-describedby={@refund_error[:acknowledgement] && @error_id}
      />
      <span class="text-tymeslot-700">{@acknowledgement}</span>
    </label>
    <p
      :if={@refund_error[:acknowledgement]}
      id={@error_id}
      class="form-error ml-6"
      role="alert"
    >
      {@refund_error[:acknowledgement]}
    </p>
    """
  end

  defp refundable_remaining(nil), do: 0
  defp refundable_remaining(payment), do: MeetingPayments.refundable_remaining_cents(payment)

  defp pending_refund(nil), do: 0
  defp pending_refund(payment), do: MeetingPayments.pending_refund_cents(payment)

  attr :booking_payment, :map, default: nil

  @doc """
  Says, before the host confirms, why cancelling refunds none of the money
  the attendee paid (`MeetingPayments.refund_refusal/1`): past the refund
  window, under dispute, or never paid. Renders nothing when nothing is owed
  or it can be refunded. Shared by the single cancel dialog and the
  cancel-remaining dialog of a series.
  """
  @spec no_refund_warning(map()) :: Phoenix.LiveView.Rendered.t()
  def no_refund_warning(assigns) do
    assigns = assign(assigns, :reason, no_refund_reason_for(assigns.booking_payment))

    ~H"""
    <.info_box :if={@reason} variant={:warning} class="mb-0!">
      {no_refund_sentence(@reason)}
    </.info_box>
    """
  end

  # Money the attendee paid that cannot be refunded from here. Nil when
  # nothing is owed, or it can be.
  defp no_refund_reason_for(payment) do
    with true <- unrefunded?(payment),
         {:error, reason} <- MeetingPayments.refund_refusal(payment) do
      reason
    else
      _refundable_or_settled -> nil
    end
  end

  # A disputed payment is not outstanding (Stripe holds the money), but
  # cancelling still refunds none of it.
  defp unrefunded?(%{status: :disputed}), do: true
  defp unrefunded?(payment), do: MeetingPayments.refund_outstanding?(payment)

  # Each refusal has its own whole sentence, so a translation is never
  # stitched together from a lower-case fragment.
  defp no_refund_sentence(:outside_refund_window),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelling won't refund the attendee: the payment is older than the 60-day refund window. You can refund it from Stripe."
      )

  defp no_refund_sentence(:under_dispute),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelling won't refund the attendee: the payment is under dispute. Settle the dispute in Stripe first."
      )

  defp no_refund_sentence(:not_paid),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelling won't refund the attendee: the booking was not paid."
      )
end
