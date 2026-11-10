defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.VisibilitySection do
  @moduledoc """
  Stateless function component for the meeting-type form's Visibility section.

  Renders one "Show on …" switch per page for a meeting type: the profile's
  own page at `/<username>` dispatches `toggle_private`, a booking page
  `toggle_page_membership`, both to the parent `ServiceSettingsComponent`
  (`@parent`), which owns persistence. Each switch sends the state it asks
  for (`phx-value-listed`), so a flip does what the host saw even when
  another tab changed the listing meanwhile.

  Above them, a switch making the type invitation-only (`toggle_invitation_only`,
  also to the parent), which hides it from every page; while it is on the page
  switches are not shown. A group type cannot be invitation-only, so the switch
  is disabled for one.

  Without a username there is no page to show a type on yet, so the section
  says to choose one instead (not for an invitation-only type, whose
  `/invite/<token>` links need no username). While the plan does not allow changing booking
  pages (`BookingPages.editable?/1`), their switches are disabled; the
  username's own page is never gated.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPages
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupRules

  attr :type, :map, default: nil
  attr :parent, :any, required: true
  attr :username, :string, default: nil
  attr :pages, :list, default: [], doc: "`PageVisibility.rows/4`, the username's page first"

  attr :group, :boolean,
    default: false,
    doc: "Whether group bookings are on: invitation links are for one-to-one types only"

  attr :pages_editable, :boolean,
    default: true,
    doc: "`BookingPages.editable?/1`: whether the booking pages' switches may be flipped"

  @spec visibility_section(map()) :: Phoenix.LiveView.Rendered.t()
  def visibility_section(assigns) do
    ~H"""
    <section :if={@type} class="space-y-4">
      <.subsection_header
        icon="hero-eye-slash"
        title={dgettext("dashboard_meeting_form", "Visibility")}
      />

      <p
        :if={@username in [nil, ""] and not @type.invitation_only}
        class="text-token-sm text-tymeslot-600"
        data-testid="visibility-needs-username"
      >
        {dgettext(
          "dashboard_meeting_form",
          "Choose a username on your Profile page first: your booking pages' addresses are built from it, so this meeting type can't be booked until you have one."
        )}
      </p>

      <.setting_row
        id={"meeting-type-invitation-only-toggle-#{@type.id}"}
        control={:switch}
        label={dgettext("dashboard_meeting_form", "Only people with an invitation link can book")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Hidden from your booking pages. Each invitation link books one appointment."
          )
        }
        checked={@type.invitation_only}
        disabled={@group and not @type.invitation_only}
        on_change="toggle_invitation_only"
        target={@parent}
        phx-value-id={@type.id}
        phx-value-invitation_only={to_string(not @type.invitation_only)}
      >
        <:disabled_reason>{GroupRules.invitation_only_message()}</:disabled_reason>
      </.setting_row>

      <.setting_row
        :for={page <- if(@type.invitation_only, do: [], else: @pages)}
        id={toggle_id(@type, page)}
        control={:switch}
        label={dgettext("dashboard_meeting_form", "Show on %{address}", address: "/" <> page.address)}
        checked={page.checked}
        disabled={locked?(page, @pages_editable)}
        on_change={toggle_event(page)}
        target={@parent}
        phx-value-id={@type.id}
        phx-value-page={page.id}
        phx-value-listed={to_string(not page.checked)}
      >
        <:disabled_reason>{BookingPages.locked_message()}</:disabled_reason>
      </.setting_row>

      <p
        :if={not @type.invitation_only and @pages != [] and Enum.all?(@pages, &(not &1.checked))}
        class="text-token-sm text-tymeslot-500"
        data-testid="unlisted-note"
      >
        {dgettext(
          "dashboard_meeting_form",
          "On no booking page: bookable only through its direct link."
        )}
      </p>
    </section>
    """
  end

  # The username's page keeps the control id and event it always had.
  defp toggle_id(type, %{id: "profile"}), do: "meeting-type-private-toggle-#{type.id}"
  defp toggle_id(type, page), do: "meeting-type-page-toggle-#{type.id}-#{page.id}"

  defp toggle_event(%{id: "profile"}), do: "toggle_private"
  defp toggle_event(_page), do: "toggle_page_membership"

  # Only the extra pages are gated by the plan, never the username's own.
  defp locked?(%{id: "profile"}, _pages_editable), do: false
  defp locked?(_page, pages_editable), do: not pages_editable
end
