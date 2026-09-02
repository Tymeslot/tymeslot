defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupBookingsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Group bookings
  section.

  Renders the "Group bookings" toggle and, when enabled, the
  participant-limit number input (2 up to the `Constraints` maximum). Group
  bookings and payments are mutually exclusive: while payment is required
  the toggle renders disabled with an explanatory hint — the parent guards
  the event server-side and the changeset enforces the rule. The toggle
  stays enabled, though, when the host has since lost charge capability
  (`payments_charges_enabled: false`): the payments toggle is unreachable
  in that state, so blocking this one too would leave the organiser with no
  way to reach group bookings at all. The parent event handler clears
  `payment_required` as part of enabling the toggle in that case.

  The toggle and input dispatch `toggle_group_bookings` and
  `change_max_participants` back to the parent `MeetingTypeForm`
  (`@myself`), which owns the socket state and auto-save. The visible input
  posts as `max_participants_input`; the canonical `max_participants` param
  is serialised from socket state (hidden input in create mode,
  `Submission.build_params/1` in edit mode), mirroring the payments
  section's `price_input`/`price` split.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :group_bookings_enabled, :boolean, required: true
  attr :max_participants, :string, required: true
  attr :payment_required, :boolean, required: true
  attr :payments_charges_enabled, :boolean, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec group_bookings_section(map()) :: Phoenix.LiveView.Rendered.t()
  def group_bookings_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center gap-2">
        <.icon name="hero-users" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-700">
          {dgettext("dashboard_meeting_form", "Group bookings")}
        </h3>
      </div>

      <.info_box :if={@payment_required and @payments_charges_enabled} variant={:info}>
        {dgettext("dashboard_meeting_form", "Turn off payments to enable group bookings.")}
      </.info_box>

      <label class={[
        "flex items-center gap-3",
        @payment_required && @payments_charges_enabled && "opacity-60 cursor-not-allowed"
      ]}>
        <input
          type="checkbox"
          class="checkbox"
          checked={@group_bookings_enabled}
          disabled={@payment_required and @payments_charges_enabled}
          phx-click="toggle_group_bookings"
          phx-target={@myself}
        />
        <span class="text-token-sm text-tymeslot-700">
          {dgettext("dashboard_meeting_form", "Let multiple people book the same time slot")}
        </span>
      </label>

      <div :if={@group_bookings_enabled and not @payment_required} class="max-w-xs">
        <.input
          type="number"
          name="meeting_type[max_participants_input]"
          label={dgettext("dashboard_meeting_form", "Participant limit")}
          value={@max_participants}
          min={Constraints.group_participants_range().first}
          max={Constraints.group_participants_range().last}
          step="1"
          phx-change="change_max_participants"
          phx-debounce="500"
          phx-target={@myself}
          errors={
            FormValidationHelpers.field_errors(@form_errors, :max_participants)
            |> Enum.map(&Helpers.format_errors/1)
          }
        />
        <p class="mt-1 text-token-sm text-tymeslot-600">
          {dgettext("dashboard_meeting_form", "Between %{min} and %{max} participants per slot.",
            min: Constraints.group_participants_range().first,
            max: Constraints.group_participants_range().last
          )}
        </p>
      </div>

      <%!-- The number input above only renders while the toggle is on and
           payment is not required. A cross-field error can still land on
           this same field while it's hidden — e.g. the changeset's mutual
           exclusion check on `:max_participants` when payment becomes
           required — so mirror the payments section's unconditional error
           outlet rather than let it go silently invisible. --%>
      <%= if not (@group_bookings_enabled and not @payment_required) do %>
        <%= for error <- FormValidationHelpers.field_errors(@form_errors, :max_participants) do %>
          <p class="form-error">{Helpers.format_errors(error)}</p>
        <% end %>
      <% end %>
    </div>
    """
  end
end
