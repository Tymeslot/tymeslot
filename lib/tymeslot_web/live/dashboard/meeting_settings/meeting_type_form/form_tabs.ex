defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.FormTabs do
  @moduledoc """
  The tabs of the meeting-type form's tab strip, as `FormView` passes them to
  `tab_bar`: each tab's label and icon, whether it carries an error dot, and
  whether it is disabled.

  A tab shows an error dot when any of the form-error fields its panel holds
  has an error. Until the meeting type exists only Details can be used; the
  other tabs are disabled and described by the hint saying why.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  # Which form-error fields surface an indicator on which tab. Errors on
  # fields absent here (e.g. :base) render below the panels and need no dot.
  @tab_error_fields %{
    "details" => [:name, :duration, :extra_lengths, :slot_interval, :description, :icon],
    "location" => [:locations, :video_integration, :calendar_integration, :target_calendar],
    "booking" => [
      :payment_required,
      :price_cents,
      :max_participants,
      :last_spots_threshold,
      :approval_window_hours,
      :series_mode,
      :series_frequency,
      :series_interval,
      :series_min_occurrences,
      :series_max_occurrences,
      :series_required
    ],
    "reminders" => [:reminder_config]
  }

  @doc """
  The form's tabs for `tab_bar`. Until the meeting type exists (`is_edit`
  false) only Details can be used; the others point at `create_hint_id`, the
  hint saying why.
  """
  @spec tabs(map(), boolean(), String.t()) :: [map()]
  def tabs(form_errors, is_edit, create_hint_id) do
    tabs = [
      %{
        id: "details",
        label: dgettext("dashboard_meeting_form", "Details"),
        icon: "hero-pencil-square"
      },
      %{
        id: "location",
        label: dgettext("dashboard_meeting_form", "Location & Calendar"),
        icon: "hero-map-pin"
      },
      %{
        id: "booking",
        label: dgettext("dashboard_meeting_form", "Booking Rules"),
        icon: "hero-adjustments-horizontal"
      },
      %{
        id: "questions",
        label: dgettext("dashboard_meeting_form", "Questions"),
        icon: "hero-chat-bubble-left-right"
      },
      %{
        id: "reminders",
        label: dgettext("dashboard_meeting_form", "Reminders"),
        icon: "hero-bell"
      }
    ]

    Enum.map(tabs, fn tab ->
      disabled? = not is_edit and tab.id != "details"

      Map.merge(tab, %{
        error: tab_has_errors?(form_errors, tab.id),
        disabled: disabled?,
        describedby: if(disabled?, do: create_hint_id)
      })
    end)
  end

  defp tab_has_errors?(form_errors, tab_id) do
    @tab_error_fields
    |> Map.get(tab_id, [])
    |> Enum.any?(&(FormValidationHelpers.field_errors(form_errors, &1) != []))
  end
end
