defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.RedirectSection do
  @moduledoc """
  Stateless function component for the meeting-type form's redirect
  section: where a booker is sent once a new booking is made, and whether
  the booking's details go with them.

  The address input dispatches `update_redirect_url` and the switch
  `toggle_redirect_pass_details`, both to the parent `MeetingTypeForm`
  (`@myself`), which owns the socket state and auto-save. An address that
  is not a full web address shows its error beside the input and is not
  saved (`Tymeslot.MeetingTypes.RedirectUrl`); the stored one stays in
  force meanwhile.

  The switch stays available without an address: in an embed it also
  decides whether the embedding page's `onSuccess` callback is told who
  booked (`Tymeslot.Bookings.RedirectParams`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.RedirectUrl

  attr :redirect_url, :string, default: nil
  attr :redirect_pass_details, :boolean, required: true
  attr :errors, :list, default: []
  attr :myself, :any, required: true

  @spec redirect_section(map()) :: Phoenix.LiveView.Rendered.t()
  def redirect_section(assigns) do
    assigns = assign(assigns, :max_length, RedirectUrl.max_length())

    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-arrow-top-right-on-square"
        title={dgettext("dashboard_meeting_form", "Redirect after booking")}
      />

      <div class="space-y-2">
        <label class="label" for="redirect-url">
          {dgettext("dashboard_meeting_form", "Redirect URL")}
        </label>

        <.input
          type="url"
          id="redirect-url"
          name="meeting_type[redirect_url]"
          value={@redirect_url}
          maxlength={@max_length}
          placeholder="https://example.com/thank-you"
          autocomplete="off"
          phx-change="update_redirect_url"
          phx-debounce="500"
          phx-target={@myself}
          data-testid="redirect-url"
        />

        <p :for={error <- @errors} class="text-token-sm text-red-600">{error}</p>

        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_form",
            "Send invitees to this page after they book instead of showing the confirmation. Leave blank to show the confirmation."
          )}
        </p>
      </div>

      <.setting_row
        id="redirect-pass-details-toggle"
        label={dgettext("dashboard_meeting_form", "Pass event details to your redirected page")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Include booking info like invitee name, email, and event time in the redirect URL"
          )
        }
        checked={@redirect_pass_details}
        on_change="toggle_redirect_pass_details"
        target={@myself}
        data-testid="redirect-pass-details-toggle"
      />
    </section>
    """
  end
end
