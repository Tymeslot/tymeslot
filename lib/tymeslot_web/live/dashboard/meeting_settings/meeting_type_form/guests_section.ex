defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GuestsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Guests section.

  Renders the "allow guests" toggle. When enabled, invitees can add extra
  guest email addresses on the public booking form; each guest receives a
  confirmation email with an RSVP link. The toggle dispatches
  `toggle_allow_guests` back to the parent `MeetingTypeForm` (`@myself`),
  which owns the socket state and auto-save.

  With guests on, the host can limit how many one booking may bring
  (`MeetingTypeForm.GuestLimit`). On a group type the section says that
  each guest takes one of the time's seats.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GuestLimit
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :allow_guests, :boolean, required: true
  attr :guest_limit, :integer, default: nil, doc: "the type's own limit, nil while off"
  attr :group_bookings_enabled, :boolean, default: false
  attr :form_errors, :map, default: %{}
  attr :myself, :any, required: true

  @spec guests_section(map()) :: Phoenix.LiveView.Rendered.t()
  def guests_section(assigns) do
    assigns = assign(assigns, :max_guests, GuestLimit.effective(assigns.guest_limit))

    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-user-group"
        title={dgettext("dashboard_meeting_form", "Guests")}
      />

      <.setting_row
        id="allow-guests-toggle"
        label={
          dgettext(
            "dashboard_meeting_form",
            "Let invitees add up to %{max_guests} guests to this meeting",
            max_guests: @max_guests
          )
        }
        description={
          dgettext(
            "dashboard_meeting_form",
            "Each guest is emailed a confirmation with their own link to accept or decline. You'll see every guest's response on your dashboard."
          )
        }
        checked={@allow_guests}
        on_change="toggle_allow_guests"
        target={@myself}
      />

      <p
        :if={@allow_guests and @group_bookings_enabled}
        class="text-token-sm text-tymeslot-600"
        data-testid="guests-take-seats"
      >
        {dgettext(
          "dashboard_meeting_form",
          "Each guest takes one of the time's seats, as the booker does."
        )}
      </p>

      <div :if={@allow_guests} class="space-y-3">
        <.setting_row
          id="guest-limit-toggle"
          label={dgettext("dashboard_meeting_form", "Limit the guests per booking")}
          description={
            dngettext(
              "dashboard_meeting_form",
              "Without a limit, each booking may bring up to %{count} guest.",
              "Without a limit, each booking may bring up to %{count} guests.",
              Guests.max_guests()
            )
          }
          checked={@guest_limit != nil}
          on_change="toggle_guest_limit"
          target={@myself}
        />

        <div :if={@guest_limit} class="max-w-xs">
          <.input
            type="number"
            name="meeting_type[guest_limit_input]"
            label={dgettext("dashboard_meeting_form", "Guests per booking")}
            value={@guest_limit}
            min={Constraints.guests_per_booking_range().first}
            max={Constraints.guests_per_booking_range().last}
            step="1"
            phx-change="change_guest_limit"
            phx-debounce="500"
            phx-target={@myself}
            errors={
              FormValidationHelpers.field_errors(@form_errors, :max_guests_per_booking)
              |> Enum.map(&Helpers.format_errors/1)
            }
          />
        </div>
      </div>
    </section>
    """
  end
end
