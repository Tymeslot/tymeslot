defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupBookingsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Group bookings
  section.

  Renders the "Group bookings" toggle and, when enabled, the
  participant-limit number input (2 up to the `Constraints` maximum).

  A group type cannot require payment or approval, and its location has to be
  fixed in advance (`Tymeslot.MeetingTypes.GroupLocationRule`). While any of
  those stands in the way (`GroupRules.enable_blocker/1`, the `blocker`
  attr), the toggle renders disabled with a hint saying what to change; the
  parent guards the event server-side and the changeset enforces the rules.
  Turning group bookings off is never blocked. The payment rule does not
  block a host who has since lost charge capability: the payments toggle is
  unreachable in that state, so the parent clears `payment_required` as part
  of enabling group bookings instead.

  Group bookings can be a paid feature. Without access (`allowed: false`) a
  one-to-one type shows the upgrade placeholder registered under
  `:feature_placeholder_components[:group_bookings]`, the same way the
  custom-questions section does; an existing group type keeps the section, so
  its host can still save it as it is or turn group bookings off.

  The toggle and input dispatch `toggle_group_bookings` and
  `change_max_participants` back to the parent `MeetingTypeForm`
  (`@myself`), which owns the socket state and auto-save. The visible input
  posts as `max_participants_input`; the canonical `max_participants` param
  is serialised from socket state by `Submission.build_params/1`, mirroring
  the payments section's `price_input`/`price` split.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.FormHelpers
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupRules
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :group_bookings_enabled, :boolean, required: true
  attr :max_participants, :string, required: true
  attr :payment_required, :boolean, required: true
  attr :blocker, :any, default: nil, doc: "`GroupRules.enable_blocker/1`'s answer"
  attr :allowed, :boolean, default: true
  attr :form_id, :string, required: true
  attr :current_user, :any, default: nil
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec group_bookings_section(map()) :: Phoenix.LiveView.Rendered.t()
  def group_bookings_section(%{allowed: false, group_bookings_enabled: false} = assigns) do
    assigns = assign(assigns, :placeholder_component, placeholder_component())

    ~H"""
    <section data-testid="group-bookings-locked">
      <%= if @placeholder_component do %>
        <.live_component
          module={@placeholder_component}
          id={"group-bookings-upgrade-#{@form_id}"}
          feature={:group_bookings}
          current_user={@current_user}
        />
      <% else %>
        <%!-- No placeholder registered: a minimal notice rather than nothing,
              so a misconfiguration is noticed. --%>
        <.card class="text-center">
          <p class="text-token-sm text-tymeslot-500">
            {FormHelpers.group_bookings_not_allowed_message()}
          </p>
        </.card>
      <% end %>
    </section>
    """
  end

  def group_bookings_section(assigns) do
    assigns =
      assign(
        assigns,
        :toggle_disabled,
        not assigns.group_bookings_enabled and assigns.blocker != nil
      )

    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-users"
        title={dgettext("dashboard_meeting_form", "Group bookings")}
      />

      <.setting_row
        id={"group-bookings-toggle-#{@form_id}"}
        label={dgettext("dashboard_meeting_form", "Let multiple people book the same time slot")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Each slot stays open until the participant limit is reached, and everyone booked into it meets together."
          )
        }
        checked={@group_bookings_enabled}
        disabled={@toggle_disabled}
        on_change="toggle_group_bookings"
        target={@myself}
      >
        <:disabled_reason>{blocker_message(@blocker)}</:disabled_reason>
      </.setting_row>

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
           this same field while it's hidden, such as the changeset's mutual
           exclusion check on `:max_participants` when payment becomes
           required, so mirror the payments section's unconditional error
           outlet rather than let it go silently invisible. --%>
      <%= if not (@group_bookings_enabled and not @payment_required) do %>
        <%= for error <- FormValidationHelpers.field_errors(@form_errors, :max_participants) do %>
          <p class="form-error">{Helpers.format_errors(error)}</p>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp blocker_message(:plan), do: FormHelpers.group_bookings_not_allowed_message()

  defp blocker_message(:payment),
    do: dgettext("dashboard_meeting_form", "Turn off payments to enable group bookings.")

  defp blocker_message(:approval),
    do: dgettext("dashboard_meeting_form", "Turn off approval to enable group bookings.")

  defp blocker_message({:location, reason}), do: GroupRules.location_message(reason)

  # Bracket access works for both a keyword list and a map. Core leaves the
  # config unset; the managed overlay registers one.
  defp placeholder_component do
    case Application.get_env(:tymeslot, :feature_placeholder_components) do
      nil -> nil
      placeholders -> placeholders[:group_bookings]
    end
  end
end
