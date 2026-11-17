defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.DetailsPanel do
  @moduledoc """
  Stateless function component for the contents of the meeting-type form's
  Details panel: the name, the meeting lengths, the booking slot interval,
  the description and the icon.

  It is the one panel a new meeting type shows before it is created, so it
  renders for both creating and editing. The inputs are part of the
  surrounding meeting-type form (no nested form element); each change
  dispatches back to the parent `MeetingTypeForm` (`@myself`), which owns the
  socket state and auto-save. The card around it, and its place in the tab
  strip, stay with `FormView`.

  The slot interval is a preset dropdown that gives way to a number input
  for a custom value; `SlotIntervalField` decides which is on screen (from
  `custom_input_mode` and the stored value), the options and the hint.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.Languages.TranslationStatus
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LengthsField
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SlotIntervalField
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import LengthsField, only: [lengths_field: 1]

  import TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents,
    only: [icon_picker: 1]

  attr :form_data, :map, required: true
  attr :form_errors, :map, default: %{}
  attr :type, :map, default: nil
  attr :group_bookings_enabled, :boolean, required: true
  attr :custom_input_mode, :map, default: %{}
  attr :selected_icon, :string, default: nil
  attr :translation_status, :map, default: nil
  attr :myself, :any, required: true

  @spec details_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def details_panel(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <.input
        name="meeting_type[name]"
        label={dgettext("dashboard_meeting_form", "Name")}
        value={Map.get(@form_data, "name", if(@type, do: @type.name, else: ""))}
        required
        maxlength={Constraints.name_length_opts()[:max]}
        placeholder={dgettext("dashboard_meeting_form", "e.g., Quick Chat")}
        phx-change="validate_meeting_type"
        phx-debounce="500"
        phx-target={@myself}
        errors={
          FormValidationHelpers.field_errors(@form_errors, :name)
          |> Enum.map(&Helpers.format_errors/1)
        }
        icon="hero-tag"
      >
        <:label_suffix>
          <TranslationStatus.mark status={@translation_status} path="name" />
        </:label_suffix>
      </.input>

      <.lengths_field
        form_data={@form_data}
        form_errors={@form_errors}
        type={@type}
        group_bookings_enabled={@group_bookings_enabled}
        myself={@myself}
      />
    </div>

    <% extra_lengths = Map.get(@form_data, "extra_lengths", []) %>
    <% slot_interval_value =
      Map.get(
        @form_data,
        "slot_interval",
        if(@type, do: @type.slot_interval_minutes, else: "")
      ) %>
    <% slot_interval_custom? = SlotIntervalField.custom?(assigns, slot_interval_value) %>
    <div>
      <.select
        id="meeting-type-slot-interval"
        name="meeting_type[slot_interval]"
        label={dgettext("dashboard_meeting_form", "Booking slot interval")}
        value={
          if(slot_interval_custom?,
            do: SlotIntervalField.custom_interval_option(),
            else: slot_interval_value
          )
        }
        options={SlotIntervalField.options(slot_interval_value, slot_interval_custom?)}
        phx-change="validate_meeting_type"
        phx-target={@myself}
        errors={
          if(slot_interval_custom?,
            do: [],
            else:
              FormValidationHelpers.field_errors(@form_errors, :slot_interval)
              |> Enum.map(&Helpers.format_errors/1)
          )
        }
        icon="hero-adjustments-horizontal"
      />
      <%!-- The number input carries the same param name as the select, so
            whichever control is on screen is the one that posts the value
            and the two can never disagree about what is stored. --%>
      <div :if={slot_interval_custom?} class="mt-2">
        <.input
          type="number"
          id="meeting_type_slot_interval_custom"
          name="meeting_type[slot_interval]"
          label={dgettext("dashboard_meeting_form", "Custom interval (minutes)")}
          value={slot_interval_value}
          min={Constraints.slot_interval_minutes_range().first}
          max={Constraints.slot_interval_minutes_range().last}
          step="1"
          phx-change="validate_meeting_type"
          phx-debounce="500"
          phx-target={@myself}
          errors={
            FormValidationHelpers.field_errors(@form_errors, :slot_interval)
            |> Enum.map(&Helpers.format_errors/1)
          }
          icon="hero-adjustments-horizontal"
        />
      </div>
      <p class="mt-1 text-token-sm text-tymeslot-600">
        {SlotIntervalField.hint(
          slot_interval_value,
          Map.get(@form_data, "duration"),
          extra_lengths
        )}
      </p>
    </div>

    <.input
      name="meeting_type[description]"
      label={dgettext("dashboard_meeting_form", "Description (optional)")}
      value={Map.get(@form_data, "description", if(@type, do: @type.description, else: ""))}
      maxlength={Constraints.description_max_length()}
      placeholder={dgettext("dashboard_meeting_form", "Brief description of this meeting type")}
      phx-change="validate_meeting_type"
      phx-debounce="500"
      phx-target={@myself}
      errors={
        FormValidationHelpers.field_errors(@form_errors, :description)
        |> Enum.map(&Helpers.format_errors/1)
      }
      icon="hero-document-text"
    >
      <:label_suffix>
        <TranslationStatus.mark status={@translation_status} path="description" />
      </:label_suffix>
    </.input>

    <.icon_picker
      selected_icon={@selected_icon}
      form_errors={@form_errors}
      myself={@myself}
    />
    """
  end
end
