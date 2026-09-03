defmodule TymeslotWeb.Dashboard.CalendarGrid.ComponentView do
  @moduledoc """
  Markup for the calendar grid component.

  Extracted from `CalendarGridComponent` so the component module stays focused on
  lifecycle and event routing. `grid/1` receives the component's assigns
  unchanged (the component's `render/1` delegates straight to it), so LiveView
  change tracking is preserved.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.GridViews
  alias TymeslotWeb.Dashboard.CalendarGrid.Header
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.BookingDetailModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDiscardAttendeesModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmRemoveAttendeeModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CreateEventModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.NotifyPromptModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ShortcutsHelpModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.AgendaView
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.EmptyState
  alias TymeslotWeb.Dashboard.OnboardingChecklist

  @doc "Renders the calendar grid: desktop-reminder hook, toolbar, views, and the modal stack."
  @spec grid(map()) :: Phoenix.LiveView.Rendered.t()
  def grid(assigns) do
    ~H"""
    <div
      id="calendar-grid"
      class="flex flex-col h-full relative"
      phx-hook="CalendarMobile"
      phx-target={@myself}
    >
      <%!-- Drives browser desktop reminders while the calendar is open. The hook
            reads the JSON feed and fires Notifications on its own timer; the feed
            refreshes on every 60s tick. --%>
      <div
        id="desktop-reminders"
        phx-hook="DesktopReminders"
        data-enabled={to_string(@preferences != nil and @preferences.desktop_reminders_enabled)}
        data-reminders={Jason.encode!(@desktop_reminders_feed)}
        hidden
      >
      </div>
      <div :if={@_initialized} class="flex-1 flex flex-col min-h-0">
        <%!-- The setup checklist already carries "Connect a calendar" as its
              first step, so the banner only appears once the checklist is gone. --%>
        <EmptyState.connect_calendar_banner :if={
          @integrations == [] and
            not OnboardingChecklist.visible?(@current_user, @integration_status)
        } />
        <Header.toolbar
          view={@view}
          date={@date}
          integrations={@integrations}
          integration_colors={@integration_colors}
          calendar_colour_keys={@calendar_colour_keys}
          hidden_integration_ids={@hidden_integration_ids}
          hidden_calendar_keys={@hidden_calendar_keys}
          show_calendar_list={@show_calendar_list}
          show_view_menu={@show_view_menu}
          mini_month_open={@mini_month_open}
          mini_month_cursor={@mini_month_cursor}
          syncing={@syncing}
          timezone_display={@timezone_display}
          timezone_country_code={@timezone_country_code}
          preferences={@preferences}
          search_term={@search_term}
          search_results={@search_results}
          search_open={@search_open}
          user_timezone={@user_timezone}
          myself={@myself}
        />
        <GridViews.week_day_view
          view={@view}
          visible_days={@visible_days}
          visible_events={@visible_events}
          events={@events}
          integrations={@integrations}
          integration_colors={@integration_colors}
          calendar_colors={@calendar_colors}
          hidden_integration_ids={@hidden_integration_ids}
          current_time={@current_time}
          user_timezone={@user_timezone}
          preferences={@preferences}
          stale_integrations={@stale_integrations}
          oldest_sync_at={@oldest_sync_at}
          syncing={@syncing}
          sync_total={@sync_total}
          sync_completed={@sync_completed}
          date={@date}
          guest_rsvp_summaries={@guest_rsvp_summaries}
          myself={@myself}
        />
        <GridViews.month_view
          view={@view}
          visible_days={@visible_days}
          visible_events={@visible_events}
          integrations={@integrations}
          integration_colors={@integration_colors}
          calendar_colors={@calendar_colors}
          hidden_integration_ids={@hidden_integration_ids}
          date={@date}
          user_timezone={@user_timezone}
          preferences={@preferences}
          guest_rsvp_summaries={@guest_rsvp_summaries}
          myself={@myself}
        />
        <AgendaView.agenda_view
          view={@view}
          visible_days={@visible_days}
          visible_events={@visible_events}
          integration_colors={@integration_colors}
          calendar_colors={@calendar_colors}
          user_timezone={@user_timezone}
          preferences={@preferences}
          agenda_lens={@agenda_lens}
          myself={@myself}
        />
        <CreateEventModal.create_event_modal
          :if={@creating_event}
          creating_event={@creating_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          saving={@saving_event}
          user_timezone={@user_timezone}
          myself={@myself}
          video_integrations={@video_integrations}
        />
        <RecurrencePromptModal.recurrence_prompt_modal
          :if={@recurrence_prompt}
          recurrence_prompt={@recurrence_prompt}
          myself={@myself}
        />
        <SettingsModal.settings_modal
          :if={@show_settings}
          preferences={@preferences}
          myself={@myself}
        />
        <ShortcutsHelpModal.shortcuts_help_modal
          :if={@show_shortcuts_help}
          myself={@myself}
        />
        <EventDetailModal.event_detail_modal
          :if={@selected_event}
          selected_event={@selected_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          calendar_colors={@calendar_colors}
          user_timezone={@user_timezone}
          time_format={Helpers.time_format(assigns)}
          myself={@myself}
          editable={EditWorkflow.event_editable?(assigns, @selected_event)}
          attendee_input={@attendee_input}
          pending_attendees={@pending_attendees}
          video_integrations={@video_integrations}
          pending_notification={@pending_notification}
        />
        <BookingDetailModal.booking_detail_modal
          :if={@selected_booking}
          booking={@selected_booking}
          user_timezone={@user_timezone}
          time_format={Helpers.time_format(assigns)}
          myself={@myself}
        />
        <NotifyPromptModal.notify_prompt_modal
          :if={@notify_prompt}
          notify_prompt={@notify_prompt}
          kind={@notify_prompt.kind}
          myself={@myself}
        />
        <ConfirmDeleteModal.confirm_delete_modal
          :if={@confirm_delete_event}
          event={@confirm_delete_event}
          deleting={@deleting_event}
          linked_to_booking={@confirm_delete_linked_to_booking}
          myself={@myself}
        />
        <ConfirmRemoveAttendeeModal.confirm_remove_attendee_modal
          :if={@confirm_remove_attendee}
          confirm_remove_attendee={@confirm_remove_attendee}
          myself={@myself}
        />
        <ConfirmDiscardAttendeesModal.confirm_discard_attendees_modal
          :if={@confirm_discard_attendees}
          count={
            if @selected_event,
              do: length(@pending_attendees),
              else: length((@creating_event || %{})[:attendees] || [])
          }
          myself={@myself}
        />
      </div>
    </div>
    """
  end
end
