defmodule TymeslotWeb.Dashboard.CalendarGrid.InitialState do
  @moduledoc """
  The calendar grid component's initial assign state.

  Keeping the (large) set of default assigns in one place keeps the component
  module focused on lifecycle and event routing rather than state declaration.
  Connected-socket data (integrations, events, preferences, timezone) is loaded
  later in `UpdateHandlers.handle_initial/2`; these are the safe pre-connect
  defaults so the template never reads an unset assign.
  """

  @doc "The default assigns applied in the component's `mount/1`."
  @spec defaults() :: map()
  def defaults do
    %{
      view: :week,
      date: Date.utc_today(),
      events: [],
      integrations: [],
      integration_colors: %{},
      loading: false,
      selected_event: nil,
      current_time: DateTime.utc_now(),
      hidden_integration_ids: [],
      preferences: nil,
      show_calendar_list: false,
      show_view_menu: false,
      mini_month_open: false,
      mini_month_cursor: nil,
      show_settings: false,
      show_shortcuts_help: false,
      creating_event: nil,
      recurrence_prompt: nil,
      confirm_delete_event: nil,
      confirm_delete_linked_to_booking: false,
      saving_event: false,
      deleting_event: false,
      video_integrations: [],
      confirm_remove_attendee: nil,
      pending_attendees: [],
      confirm_discard_attendees: false,
      attendee_input: "",
      notify_prompt: nil,
      pending_notification: false,
      owned_integration_ids: MapSet.new(),
      visible_events: [],
      guest_rsvp_summaries: %{},
      visible_days: [],
      user_timezone: "UTC",
      timezone_display: "UTC",
      timezone_country_code: nil,
      syncing: false,
      sync_total: 0,
      sync_completed: 0,
      stale_integrations: [],
      oldest_sync_at: nil,
      search_term: "",
      search_results: [],
      search_open: false,
      _initialized: false
    }
  end
end
