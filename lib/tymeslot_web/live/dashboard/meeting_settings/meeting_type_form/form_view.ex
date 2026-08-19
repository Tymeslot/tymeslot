defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.FormView do
  @moduledoc """
  Markup for the meeting type form.

  Extracted from `MeetingTypeForm` so that module stays focused on lifecycle
  and event routing, matching how `CalendarSettings.ComponentView` sits behind
  `CalendarSettingsComponent`. `form/1` receives the component's assigns
  unchanged (its `render/1` delegates straight to it), so LiveView change
  tracking is preserved.

  The sections are grouped into five panels. In edit mode a tab bar shows one
  panel at a time; in create mode the same panels render stacked, so the
  markup below is the single source of the section grouping and order for
  both modes. Inactive panels are hidden with CSS rather than conditionally
  rendered, keeping every input in the DOM (create mode submits the whole
  form) and preserving the custom-questions component's state across tab
  switches.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{
    ApprovalSection,
    Autosave,
    AvailabilitySection,
    CustomQuestionsSection,
    GuestsSection,
    HiddenFields,
    LimitsSection,
    PaymentsSection,
    QuestionEditorComponent,
    ShowAsFreeSection,
    VisibilitySection
  }

  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import ApprovalSection, only: [approval_section: 1]
  import AvailabilitySection, only: [availability_section: 1]
  import GuestsSection, only: [guests_section: 1]
  import LimitsSection, only: [limits_section: 1]
  import ShowAsFreeSection, only: [show_as_free_section: 1]
  import HiddenFields, only: [hidden_fields: 1]
  import PaymentsSection, only: [payments_section: 1]
  import VisibilitySection, only: [visibility_section: 1]
  import TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents
  import TymeslotWeb.Dashboard.MeetingSettings.Components.Reminders

  # Which form-error fields surface an indicator on which tab. Errors on
  # fields absent here (e.g. :base) render below the panels and need no dot.
  @tab_error_fields %{
    "details" => [:name, :duration, :description, :icon],
    "location" => [:video_integration, :calendar_integration, :target_calendar],
    "booking" => [:payment_required, :price_cents, :approval_window_hours],
    "reminders" => [:reminder_config]
  }

  @spec form(map()) :: Phoenix.LiveView.Rendered.t()
  def form(assigns) do
    ~H"""
    <div id={"meeting-type-form-wrapper-#{@id}"}>
      <form
        id={"meeting-type-form-#{@id}"}
        phx-submit={if @is_edit, do: "flush_autosave", else: "save_meeting_type"}
        phx-target={if @is_edit, do: @myself, else: @parent_myself}
        class={if @is_edit, do: "space-y-6", else: "space-y-8"}
      >
        <.tab_bar
          :if={@is_edit}
          active_tab={@active_tab}
          target={@myself}
          tabs={form_tabs(@form_errors)}
        />

        <%!-- Details --%>
        <div
          id="panel-details"
          role={@is_edit && "tabpanel"}
          aria-labelledby={@is_edit && "tab-details"}
          hidden={@is_edit && @active_tab != "details"}
          class={panel_class(@is_edit, @active_tab, "details")}
        >
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
            />

            <div>
              <.input
                type="number"
                name="meeting_type[duration]"
                label={dgettext("dashboard_meeting_form", "Duration (minutes)")}
                value={
                  Map.get(@form_data, "duration", if(@type, do: @type.duration_minutes, else: "30"))
                }
                min={Constraints.duration_minutes_form_min()}
                max={Constraints.duration_minutes_opts()[:less_than_or_equal_to]}
                step="5"
                required
                placeholder="30"
                phx-change="validate_meeting_type"
                phx-debounce="500"
                phx-target={@myself}
                errors={
                  FormValidationHelpers.field_errors(@form_errors, :duration)
                  |> Enum.map(&Helpers.format_errors/1)
                }
                icon="hero-clock"
              />
              <p class="mt-1 text-token-sm text-tymeslot-600">
                {dgettext(
                  "dashboard_meeting_form",
                  "Enter a duration between %{min} and %{max} minutes",
                  min: Constraints.duration_minutes_form_min(),
                  max: Constraints.duration_minutes_opts()[:less_than_or_equal_to]
                )}
              </p>
            </div>
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
          />

          <.icon_picker
            selected_icon={@selected_icon}
            form_errors={@form_errors}
            myself={@myself}
          />
        </div>

        <%!-- Location & Calendar --%>
        <div
          id="panel-location"
          role={@is_edit && "tabpanel"}
          aria-labelledby={@is_edit && "tab-location"}
          hidden={@is_edit && @active_tab != "location"}
          class={panel_class(@is_edit, @active_tab, "location")}
        >
          <.meeting_mode_section
            meeting_mode={@meeting_mode}
            video_integrations={@video_integrations}
            selected_video_integration_id={@selected_video_integration_id}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.booking_destination_section
            calendar_integrations={@calendar_integrations}
            selected_calendar_integration_id={@selected_calendar_integration_id}
            refreshing_calendars={@refreshing_calendars}
            available_calendars={@available_calendars}
            no_writable_calendars={@no_writable_calendars}
            selected_target_calendar_id={@selected_target_calendar_id}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.show_as_free_section show_as_free={@show_as_free} myself={@myself} />
        </div>

        <%!-- Booking Rules --%>
        <div
          id="panel-booking"
          role={@is_edit && "tabpanel"}
          aria-labelledby={@is_edit && "tab-booking"}
          hidden={@is_edit && @active_tab != "booking"}
          class={panel_class(@is_edit, @active_tab, "booking")}
        >
          <.payments_section
            :if={@payments_feature_enabled}
            charges_enabled={@payments_charges_enabled}
            payment_required={@payment_required}
            payment_price={@payment_price}
            currency={@payment_currency}
            currency_minimum_cents={@payment_currency_minimum_cents}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.guests_section
            allow_guests={@allow_guests}
            max_guests={Guests.max_guests()}
            myself={@myself}
          />

          <.approval_section
            requires_approval={@requires_approval}
            approval_window_hours={@approval_window_hours}
            errors={
              @form_errors
              |> FormValidationHelpers.field_errors(:approval_window_hours)
              |> Enum.map(&Helpers.format_errors/1)
            }
            myself={@myself}
          />

          <.availability_section
            schedules={@schedules}
            default_schedule_name={@default_schedule_name}
            selected_availability_schedule_id={@selected_availability_schedule_id}
            myself={@myself}
          />

          <.limits_section booking_limits={@booking_limits} myself={@myself} />

          <.visibility_section :if={@is_edit && @type} type={@type} parent={@parent_myself} />
        </div>

        <%!-- Questions --%>
        <div
          id="panel-questions"
          role={@is_edit && "tabpanel"}
          aria-labelledby={@is_edit && "tab-questions"}
          hidden={@is_edit && @active_tab != "questions"}
          class={panel_class(@is_edit, @active_tab, "questions")}
        >
          <.live_component
            module={CustomQuestionsSection}
            id={"custom-questions-section-#{@id}"}
            custom_fields={@custom_fields}
            form_id={@id}
            allowed={@custom_questions_allowed}
            current_user={@current_user}
          />
        </div>

        <%!-- Reminders --%>
        <div
          id="panel-reminders"
          role={@is_edit && "tabpanel"}
          aria-labelledby={@is_edit && "tab-reminders"}
          hidden={@is_edit && @active_tab != "reminders"}
          class={panel_class(@is_edit, @active_tab, "reminders")}
        >
          <.reminders_section
            reminders={@reminders}
            new_reminder_value={@new_reminder_value}
            new_reminder_unit={@new_reminder_unit}
            reminder_error={@reminder_error}
            show_custom_reminder={@show_custom_reminder}
            reminder_confirmation={@reminder_confirmation}
            form_errors={@form_errors}
            myself={@myself}
          />
        </div>

        <%!-- Create-mode form serialisation. Edits auto-save from socket assigns
           (see Autosave/Submission) and never post the form, so these hidden
           inputs are only needed when creating. --%>
        <.hidden_fields
          :if={!@is_edit}
          type={@type}
          meeting_mode={@meeting_mode}
          selected_icon={@selected_icon}
          selected_video_integration_id={@selected_video_integration_id}
          selected_calendar_integration_id={@selected_calendar_integration_id}
          selected_target_calendar_id={@selected_target_calendar_id}
          selected_availability_schedule_id={@selected_availability_schedule_id}
          reminders={@reminders}
          custom_fields={@custom_fields}
          custom_questions_allowed={@custom_questions_allowed}
          payments_feature_enabled={@payments_feature_enabled}
          payments_charges_enabled={@payments_charges_enabled}
          payment_required={@payment_required}
          payment_price={@payment_price}
          allow_guests={@allow_guests}
          requires_approval={@requires_approval}
          approval_window_hours={@approval_window_hours}
          show_as_free={@show_as_free}
        />

        <%= for error <- FormValidationHelpers.field_errors(@form_errors, :base) do %>
          <p class="form-error">{Helpers.format_errors(error)}</p>
        <% end %>

        <div class="flex items-center justify-between gap-4">
          <%= if @is_edit do %>
            <Autosave.indicator status={@save_status} />
            <button
              type="button"
              phx-click="close_edit_overlay"
              phx-target={@parent_myself}
              class="btn btn-primary"
            >
              {dgettext("dashboard_meeting_form", "Done")}
            </button>
          <% else %>
            <span></span>
            <div class="flex justify-end space-x-3">
              <button
                type="button"
                phx-click="toggle_add_form"
                phx-target={@parent_myself}
                class="btn btn-secondary"
              >
                {dgettext("dashboard_meeting_form", "Cancel")}
              </button>
              <button
                type="submit"
                disabled={@saving || @refreshing_calendars}
                class="btn btn-primary"
              >
                <%= if @saving do %>
                  <span class="flex items-center">
                    <.spinner class="h-4 w-4 mr-2" />
                    {dgettext("dashboard_meeting_form", "Saving...")}
                  </span>
                <% else %>
                  {dgettext("dashboard_meeting_form", "Create Meeting Type")}
                <% end %>
              </button>
            </div>
          <% end %>
        </div>
      </form>

      <%!-- Question editor modal — rendered outside <form> to avoid nested forms --%>
      <%= if @editing_question do %>
        <.live_component
          module={QuestionEditorComponent}
          id={"question-editor-#{@id}"}
          definition={@editing_question}
          existing_fields={@custom_fields}
          form_id={@id}
          mode={@editing_question_mode}
        />
      <% end %>
    </div>
    """
  end

  defp form_tabs(form_errors) do
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

    Enum.map(tabs, &Map.put(&1, :error, tab_has_errors?(form_errors, &1.id)))
  end

  defp tab_has_errors?(form_errors, tab_id) do
    @tab_error_fields
    |> Map.get(tab_id, [])
    |> Enum.any?(&(FormValidationHelpers.field_errors(form_errors, &1) != []))
  end

  # In create mode the panels are invisible groupings in one stacked form;
  # in edit mode each is a card and only the active one is shown.
  defp panel_class(false = _is_edit, _active_tab, _panel_id), do: "space-y-4"

  defp panel_class(true = _is_edit, active_tab, panel_id) do
    ["card-glass space-y-6", active_tab != panel_id && "hidden"]
  end
end
