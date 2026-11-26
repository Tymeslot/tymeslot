defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.FormView do
  @moduledoc """
  Markup for the meeting type form.

  `MeetingTypeForm` keeps to lifecycle and event routing; the markup lives here,
  as `CalendarSettings.ComponentView` sits behind `CalendarSettingsComponent`.
  `form/1` receives the component's assigns unchanged (its `render/1` delegates
  straight to it), so LiveView change tracking is preserved.

  The sections are grouped into five panels behind a tab bar, one panel shown
  at a time. Inactive panels are hidden with CSS rather than conditionally
  rendered, preserving the custom-questions component's state across tab
  switches. The Details panel's fields render from `DetailsPanel`, and the
  tab strip's tabs (labels, error dots, disabled state) come from `FormTabs`.

  A new meeting type uses the same form. Auto-save needs a record to save
  into, so until it exists only the Details panel renders, the other tabs are
  shown but disabled, and the footer offers a single "Create meeting type"
  action in place of the auto-save indicator and "Done".
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Languages.TranslationStatus
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.PageVisibility

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{
    ApprovalSection,
    Autosave,
    AvailabilitySection,
    CustomQuestionsSection,
    DetailsPanel,
    EmailVerificationSection,
    FixedDatesSection,
    FormTabs,
    GroupBookingsSection,
    GroupRules,
    GuestsSection,
    LimitsSection,
    LocationEditorComponent,
    LocationsSection,
    PaymentsSection,
    QuestionEditorComponent,
    SchedulingRulesSection,
    SeriesHandlers,
    SeriesSection,
    SessionHandlers,
    ShowAsFreeSection,
    VisibilitySection
  }

  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import ApprovalSection, only: [approval_section: 1]
  import DetailsPanel, only: [details_panel: 1]
  import EmailVerificationSection, only: [email_verification_section: 1]
  import AvailabilitySection, only: [availability_section: 1]
  import FixedDatesSection, only: [fixed_dates_section: 1]
  import GroupBookingsSection, only: [group_bookings_section: 1]
  import GuestsSection, only: [guests_section: 1]
  import LimitsSection, only: [limits_section: 1]
  import SchedulingRulesSection, only: [scheduling_rules_section: 1]
  import SeriesSection, only: [series_section: 1]
  import ShowAsFreeSection, only: [show_as_free_section: 1]
  import PaymentsSection, only: [payments_section: 1]
  import VisibilitySection, only: [visibility_section: 1]
  import TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents
  import TymeslotWeb.Components.Shared.ReminderPicker, only: [reminder_picker: 1]

  @tabs_id "meeting-type-form-tabs"

  @doc """
  The element id of the tab button for `tab` in the form's tab strip, so a
  caller can move focus onto it.
  """
  @spec tab_element_id(String.t()) :: String.t()
  def tab_element_id(tab), do: Navigation.tab_id(@tabs_id, tab)

  @spec form(map()) :: Phoenix.LiveView.Rendered.t()
  def form(assigns) do
    assigns =
      assign(assigns,
        tabs_id: @tabs_id,
        create_hint_id: "meeting-type-form-#{assigns.id}-create-hint",
        translation_status:
          if(assigns.is_edit,
            do:
              TranslationStatus.build(
                assigns.profile,
                :meeting_types,
                :meeting_type,
                assigns.type
              )
          )
      )

    ~H"""
    <div id={"meeting-type-form-wrapper-#{@id}"}>
      <form
        id={"meeting-type-form-#{@id}"}
        phx-submit={if @is_edit, do: "flush_autosave", else: "create_meeting_type"}
        phx-target={@myself}
        class="space-y-6"
        novalidate
      >
        <TranslationStatus.strip status={@translation_status} />

        <div class="space-y-2">
          <.tab_bar
            id={@tabs_id}
            aria_label={dgettext("dashboard_meeting_form", "Meeting type settings")}
            active_tab={@active_tab}
            target={@myself}
            tabs={FormTabs.tabs(@form_errors, @is_edit, @create_hint_id)}
          />
          <p
            :if={!@is_edit}
            id={@create_hint_id}
            class="flex items-center gap-1.5 px-2 text-token-sm text-tymeslot-500"
          >
            <.icon name="hero-information-circle-mini" class="w-4 h-4 shrink-0 text-tymeslot-400" />
            {dgettext("dashboard_meeting_form", "Create the meeting type to set up the rest.")}
          </p>
        </div>

        <%!-- Details --%>
        <.card
          id={Navigation.panel_id(@tabs_id, "details")}
          role="tabpanel"
          aria-labelledby={Navigation.tab_id(@tabs_id, "details")}
          hidden={@active_tab != "details"}
          class={panel_class(@active_tab, "details")}
        >
          <.details_panel
            form_data={@form_data}
            form_errors={@form_errors}
            type={@type}
            group_bookings_enabled={@group_bookings_enabled}
            custom_input_mode={@custom_input_mode}
            selected_icon={@selected_icon}
            translation_status={@translation_status}
            myself={@myself}
          />
        </.card>

        <%!-- Location & Calendar --%>
        <.card
          :if={@is_edit}
          id={Navigation.panel_id(@tabs_id, "location")}
          role="tabpanel"
          aria-labelledby={Navigation.tab_id(@tabs_id, "location")}
          hidden={@active_tab != "location"}
          class={panel_class(@active_tab, "location")}
        >
          <.live_component
            module={LocationsSection}
            id={"locations-section-#{@id}"}
            locations={@locations}
            video_integrations={@video_integrations}
            venues={@venues}
            form_id={@id}
            group_bookings_enabled={@group_bookings_enabled}
            translation_status={@translation_status}
            errors={
              @form_errors
              |> FormValidationHelpers.field_errors(:locations)
              |> Enum.map(&Helpers.format_errors/1)
            }
          />

          <.booking_destination_section
            calendar_integrations={@calendar_integrations}
            selected_calendar_integration_id={@selected_calendar_integration_id}
            refreshing_calendars={@refreshing_calendars}
            available_calendars={@available_calendars}
            no_writable_calendars={@no_writable_calendars}
            target_calendar_status={@target_calendar_status}
            selected_target_calendar_id={@selected_target_calendar_id}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.show_as_free_section show_as_free={@show_as_free} myself={@myself} />
        </.card>

        <%!-- Booking Rules --%>
        <.card
          :if={@is_edit}
          id={Navigation.panel_id(@tabs_id, "booking")}
          role="tabpanel"
          aria-labelledby={Navigation.tab_id(@tabs_id, "booking")}
          hidden={@active_tab != "booking"}
          class={panel_class(@active_tab, "booking")}
        >
          <.payments_section
            :if={@payments_feature_enabled}
            charges_enabled={@payments_charges_enabled}
            group_bookings_enabled={@group_bookings_enabled}
            requires_email_verification={@requires_email_verification}
            payment_required={@payment_required}
            payment_price={@payment_price}
            currency={@payment_currency}
            currency_support={@payment_currency_support}
            account_currency={@payment_account_currency}
            stored_price={@payment_stored_price}
            currency_minimum_cents={@payment_currency_minimum_cents}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.group_bookings_section
            group_bookings_enabled={@group_bookings_enabled}
            max_participants={@max_participants}
            show_seat_availability={@show_seat_availability}
            last_spots_threshold={@last_spots_threshold}
            blocker={
              GroupRules.enable_blocker(%{
                type: @type,
                group_bookings_allowed: @group_bookings_allowed,
                requires_approval: @requires_approval,
                requires_email_verification: @requires_email_verification,
                extra_lengths: Map.get(@form_data, "extra_lengths", []),
                locations: @locations,
                fixed_dates: @fixed_dates,
                offered_time_rows: @offered_time_rows
              })
            }
            allowed={@group_bookings_allowed}
            dates_planned={
              SessionHandlers.dates_planned?(%{
                fixed_dates: @fixed_dates,
                session_rows: @session_rows
              })
            }
            form_id={@id}
            current_user={@current_user}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.series_section
            series={@series}
            allowed={@recurring_bookings_allowed}
            type={@type}
            fixed_dates={@fixed_dates}
            requires_email_verification={@requires_email_verification}
            booking_window_days={
              SchedulingRulesSection.booking_window_days(
                @scheduling_rules,
                @schedules,
                @selected_availability_schedule_id
              )
            }
            booking_limits={@booking_limits}
            group={@group_bookings_enabled}
            allow_guests={@allow_guests}
            payment_required={@payment_required}
            payment_price={@payment_price}
            payment_currency={@payment_currency}
            form_id={@id}
            current_user={@current_user}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.fixed_dates_section
            fixed_dates={@fixed_dates}
            group={@group_bookings_enabled}
            is_edit={@is_edit}
            sessions={@session_rows}
            offered_times={@offered_time_rows}
            new_offered_time={@new_offered_time}
            offered_time_error={@offered_time_error}
            offered_time_notice={@offered_time_notice}
            timezone={@host_timezone}
            new_session={@new_session}
            session_error={@session_error}
            session_notice={@session_notice}
            confirming_session_id={@confirming_session_id}
            confirming_seat_refunds={@confirming_seat_refunds}
            editing_session={@editing_session}
            form_id={@id}
            myself={@myself}
          />

          <.guests_section
            allow_guests={@allow_guests}
            guest_limit={@guest_limit}
            group_bookings_enabled={@group_bookings_enabled}
            form_errors={@form_errors}
            myself={@myself}
          />

          <.approval_section
            requires_approval={@requires_approval}
            group_bookings_enabled={@group_bookings_enabled}
            approval_window_hours={@approval_window_hours}
            errors={
              @form_errors
              |> FormValidationHelpers.field_errors(:approval_window_hours)
              |> Enum.map(&Helpers.format_errors/1)
            }
            myself={@myself}
          />

          <.email_verification_section
            requires_email_verification={@requires_email_verification}
            payment_required={@payment_required}
            series_enabled={@series.series_mode != nil}
            errors={
              @form_errors
              |> FormValidationHelpers.field_errors(:requires_email_verification)
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

          <.scheduling_rules_section
            scheduling_rules={@scheduling_rules}
            schedules={@schedules}
            selected_availability_schedule_id={@selected_availability_schedule_id}
            form_errors={@form_errors}
            series={@recurring_bookings_allowed and @series.series_mode != nil}
            myself={@myself}
          />

          <.limits_section
            booking_limits={@booking_limits}
            week_start={@week_start}
            series_notes={
              if @recurring_bookings_allowed,
                do: SeriesHandlers.limit_notes(@series, @booking_limits),
                else: []
            }
            myself={@myself}
          />

          <.visibility_section
            type={@type}
            parent={@parent_myself}
            group={@group_bookings_enabled}
            username={@username}
            pages={PageVisibility.rows(@username, @booking_pages, @page_memberships, @type)}
            pages_editable={@pages_editable}
          />
        </.card>

        <%!-- Questions --%>
        <.card
          :if={@is_edit}
          id={Navigation.panel_id(@tabs_id, "questions")}
          role="tabpanel"
          aria-labelledby={Navigation.tab_id(@tabs_id, "questions")}
          hidden={@active_tab != "questions"}
          class={panel_class(@active_tab, "questions")}
        >
          <.live_component
            module={CustomQuestionsSection}
            id={"custom-questions-section-#{@id}"}
            custom_fields={@custom_fields}
            form_id={@id}
            allowed={@custom_questions_allowed}
            current_user={@current_user}
            translation_status={@translation_status}
          />
        </.card>

        <%!-- Reminders --%>
        <.card
          :if={@is_edit}
          id={Navigation.panel_id(@tabs_id, "reminders")}
          role="tabpanel"
          aria-labelledby={Navigation.tab_id(@tabs_id, "reminders")}
          hidden={@active_tab != "reminders"}
          class={panel_class(@active_tab, "reminders")}
        >
          <.reminder_picker
            reminders={@reminders}
            max_reminders={@max_reminders}
            new_reminder_value={@new_reminder_value}
            new_reminder_unit={@new_reminder_unit}
            reminder_error={@reminder_error}
            show_custom_reminder={@show_custom_reminder}
            reminder_confirmation={@reminder_confirmation}
            description={
              dngettext(
                "dashboard_meeting_form",
                "Add up to %{count} reminder email for this meeting type. We recommend using only one.",
                "Add up to %{count} reminder emails for this meeting type. We recommend using only one.",
                @max_reminders
              )
            }
            extra_errors={
              @form_errors
              |> FormValidationHelpers.field_errors(:reminder_config)
              |> Enum.map(&Helpers.format_errors/1)
            }
            myself={@myself}
          />
        </.card>

        <%= for error <- FormValidationHelpers.field_errors(@form_errors, :base) do %>
          <p class="form-error">{Helpers.format_errors(error)}</p>
        <% end %>

        <div class="flex items-center justify-between gap-4">
          <%= if @is_edit do %>
            <Autosave.indicator status={@save_status} />
            <.action_button phx-click="close_edit_overlay" phx-target={@parent_myself}>
              {dgettext("dashboard_meeting_form", "Done")}
            </.action_button>
          <% else %>
            <span></span>
            <div class="flex justify-end gap-3">
              <.action_button
                variant={:secondary}
                phx-click="toggle_add_form"
                phx-target={@parent_myself}
              >
                {dgettext("dashboard_meeting_form", "Cancel")}
              </.action_button>
              <%!-- LiveView marks the form phx-submit-loading and disables
                    this button for the round trip, which is what swaps the
                    label for the spinner. --%>
              <.action_button type="submit" data-testid="create-meeting-type">
                <span class="hidden items-center gap-2 phx-submit-loading:inline-flex">
                  <.spinner />
                  {dgettext("dashboard_meeting_form", "Creating…")}
                </span>
                <span class="phx-submit-loading:hidden">
                  {dgettext("dashboard_meeting_form", "Create meeting type")}
                </span>
              </.action_button>
            </div>
          <% end %>
        </div>
      </form>

      <%!-- Location editor modal — rendered outside <form> to avoid nested forms --%>
      <%= if @editing_location do %>
        <.live_component
          module={LocationEditorComponent}
          id={"location-editor-#{@id}"}
          location={@editing_location}
          existing_locations={@locations}
          group_bookings_enabled={@group_bookings_enabled}
          video_integrations={@video_integrations}
          venues={@venues}
          current_user={@current_user}
          parent_myself={@parent_myself}
          form_id={@id}
          mode={@editing_location_mode}
        />
      <% end %>

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

  defp panel_class(active_tab, panel_id) do
    ["space-y-6", active_tab != panel_id && "hidden"]
  end
end
