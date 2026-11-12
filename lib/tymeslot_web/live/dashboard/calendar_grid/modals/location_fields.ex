defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.LocationFields do
  @moduledoc """
  The location of an event or a meeting created from Quick add: none, one of
  the host's saved locations (`Tymeslot.Venues`), or a place they type in.

  A video call is not offered here: it has its own picker, since a room is
  created on a provider rather than named. A group event chooses its one
  place in its own fields (`GroupEventFields`).

  Enter in the text field submits the form; `phx-submit` takes it as one
  more change, since a form with only `phx-change` is submitted natively by
  LiveView and would reload the page.

  The choice is posted as `location_choice`: `""` for none, `"venue:<id>"`
  for a saved location, `"custom"` for one typed into `location_custom`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.CreateAdHoc

  attr :choice, :string, required: true, doc: "the form state's `:location_choice`"
  attr :custom, :string, required: true, doc: "the form state's `:location_custom`"
  attr :venues, :list, default: []
  attr :myself, :any, required: true

  @spec location_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def location_fields(assigns) do
    ~H"""
    <form
      id="create-location-form"
      class="mb-3 space-y-2"
      phx-change="update_create_location"
      phx-submit="update_create_location"
      phx-target={@myself}
      novalidate
    >
      <.select
        id="create-location-choice"
        name="location_choice"
        label={dgettext("dashboard_calendar_location", "Location (optional)")}
        prompt={dgettext("dashboard_calendar_location", "No location")}
        options={options(@venues)}
        value={@choice}
      />
      <.input
        :if={@choice == "custom"}
        type="text"
        id="create-location-custom"
        name="location_custom"
        value={@custom}
        maxlength={CreateAdHoc.custom_location_max_length()}
        placeholder={dgettext("dashboard_calendar_location", "An address, a room or a meeting point")}
        aria-label={dgettext("dashboard_calendar_location", "Custom location")}
        phx-debounce="300"
      />
      <p class="text-token-xs text-tymeslot-400">
        {dgettext(
          "dashboard_calendar_location",
          "Shown on the calendar entry and in every invitation."
        )}
      </p>
    </form>
    """
  end

  # Grouped as `options_for_select/2` takes them; the saved locations are
  # left out when the host has none.
  defp options(venues) do
    saved =
      case venues do
        [] ->
          []

        _some ->
          [{dgettext("dashboard_calendar_location", "Saved locations"), venue_options(venues)}]
      end

    saved ++ [{dgettext("dashboard_calendar_location", "Custom location…"), "custom"}]
  end

  defp venue_options(venues), do: Enum.map(venues, &{&1.name, "venue:#{&1.id}"})
end
