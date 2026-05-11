defmodule TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal do
  @moduledoc """
  Modal component for confirming meeting cancellation.

  When the meeting has an associated paid `booking_payment`, the modal
  shows three refund options: full refund, partial refund, or cancel
  without refunding (gated behind a confirmation tickbox). For free
  bookings the modal preserves the original confirm-or-keep flow.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Components.PaymentHelpers

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
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :cancelling, :boolean, required: true
  attr :on_cancel, JS, required: true
  attr :confirm_event, :string, required: true
  attr :target, :any, required: true
  attr :booking_payment, :map, default: nil

  @spec cancel_meeting_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_meeting_modal(assigns) do
    assigns = assign(assigns, :paid?, MeetingPayments.refundable?(assigns[:booking_payment]))

    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          Cancel Meeting
        </div>
      </:header>

      <form
        :if={@meeting}
        id="cancel-meeting-form"
        phx-submit={@confirm_event}
        phx-target={@target}
        class="space-y-4"
      >
        <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
          Are you sure you want to cancel the meeting with <strong>{@meeting.attendee_name}</strong>
          scheduled for <strong>{Helpers.format_meeting_date(@meeting, @timezone)} • {Helpers.format_meeting_time(@meeting, @timezone)}</strong>?
        </p>

        <.paid_options :if={@paid?} booking_payment={@booking_payment} />
        <p :if={not @paid?} class="text-tymeslot-500 font-medium">
          This action cannot be undone. The attendee will be notified of the cancellation.
        </p>
      </form>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            Keep Meeting
          </CoreComponents.action_button>
          <CoreComponents.loading_button
            type="submit"
            form="cancel-meeting-form"
            variant={:danger}
            loading={@cancelling}
            loading_text="Cancelling..."
          >
            {if @paid?, do: "Confirm cancellation", else: "Cancel Meeting"}
          </CoreComponents.loading_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  defp paid_options(assigns) do
    assigns = assign(assigns, :remaining, refundable_remaining(assigns.booking_payment))

    ~H"""
    <div class="rounded-token-md border border-tymeslot-200 bg-tymeslot-50 p-3 text-token-sm space-y-3">
      <p>
        This booking was paid. Choose how to handle the refund — the attendee always
        receives the full amount you refund.
      </p>

      <div class="space-y-2">
        <label class="flex items-start gap-2">
          <input
            type="radio"
            name="cancel_refund_choice"
            value="full"
            checked
          />
          <span>
            <strong>Full refund.</strong>
            Refunds the remaining balance ({format_amount(@remaining, @booking_payment.currency)}).
          </span>
        </label>

        <label class="flex items-start gap-2">
          <input
            type="radio"
            name="cancel_refund_choice"
            value="partial"
          />
          <span>
            <strong>Partial refund.</strong>
            Refund only part of the booking amount.
          </span>
        </label>

        <div class="ml-6">
          <CoreComponents.input
            type="number"
            name="cancel_refund_amount"
            label="Partial amount"
            min="0.01"
            max={@remaining / 100}
            step="0.01"
            placeholder={"0.00 #{String.upcase(@booking_payment.currency || "")}"}
          />
        </div>

        <label class="flex items-start gap-2">
          <input
            type="radio"
            name="cancel_refund_choice"
            value="none"
          />
          <span>
            <strong>Cancel without refund.</strong>
            The attendee keeps no money. Use only if the attendee already agreed.
          </span>
        </label>

        <label class="flex items-start gap-2 ml-6">
          <input
            type="checkbox"
            name="cancel_refund_no_refund_ack"
            value="true"
          />
          <span class="text-tymeslot-700">
            I understand the attendee will not receive a refund.
          </span>
        </label>
      </div>
    </div>
    """
  end

  defp refundable_remaining(%{amount_cents: amount, refunded_amount_cents: refunded}),
    do: max(amount - refunded, 0)

  defp refundable_remaining(_payment), do: 0

  defp format_amount(cents, currency), do: PaymentHelpers.format_amount(cents, currency)
end
