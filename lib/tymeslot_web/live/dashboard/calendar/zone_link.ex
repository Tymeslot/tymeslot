defmodule TymeslotWeb.Dashboard.Calendar.ZoneLink do
  @moduledoc """
  The organiser's time zone, which every time on the calendar is shown in: its
  flag and name, drawn by the shared component
  (`TymeslotWeb.Dashboard.Availability.Helpers.timezone_display/1`), as a
  link to the profile settings where the zone is changed. Its accessible
  name and tooltip say what the zone is for ("Times shown in Kyiv,
  Ukraine"). The rail shows it at its foot and the Calendars sheet beside
  the display options, so the toolbar spends no width on it. With the rail
  closed on a desktop the zone is not shown (a deliberate decision of the
  calendar plan).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Dashboard.Availability.Helpers, as: AvailabilityHelpers

  attr :id, :string, required: true

  attr :timezone, :string,
    required: true,
    doc: "the zone the surface reads times in (`Profiles.timezone/1`)"

  attr :class, :any, default: nil

  @spec zone_link(map()) :: Phoenix.LiveView.Rendered.t()
  def zone_link(assigns) do
    display = Timezones.format(assigns.timezone)

    assigns =
      assign(assigns,
        display: display,
        country_code: Timezones.country_code(assigns.timezone),
        label: dgettext("dashboard_common", "Times shown in %{timezone}", timezone: display)
      )

    ~H"""
    <.tooltip text={@label}>
      <.link
        id={@id}
        patch={~p"/dashboard/settings"}
        aria-label={@label}
        class={[
          "flex min-h-11 items-center rounded-token-md hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 md:min-h-8",
          @class
        ]}
      >
        <AvailabilityHelpers.timezone_display
          timezone_display={@display}
          country_code={@country_code}
          title={false}
        />
      </.link>
    </.tooltip>
    """
  end
end
