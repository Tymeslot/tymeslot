defmodule TymeslotWeb.Dashboard.CalendarGrid.InitialState do
  @moduledoc """
  The calendar grid component's initial assign state.

  Keeping the (large) set of default assigns in one place keeps the component
  module focused on lifecycle and event routing rather than state declaration.
  Connected-socket data (integrations, events, preferences, timezone) is loaded
  later in `UpdateHandlers.handle_initial/2`; these are the safe pre-connect
  defaults so the template never reads an unset assign.
  """

  alias Tymeslot.Timezones

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
      selected_booking: nil,
      agenda_lens: :all,
      current_time: DateTime.utc_now(),
      hidden_integration_ids: [],
      # Seeded empty so the first static render, which happens before
      # `load_integrations/1` has run, has the same assign shape as every render
      # after it.
      calendar_colors: %{},
      calendar_colour_keys: %{},
      hidden_calendar_keys: MapSet.new(),
      mirror_uids: MapSet.new(),
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
      # Overwritten from the profile in `UpdateHandlers.handle_initial/2` before
      # the first render, on the static pass as much as the connected one. These
      # only stand in for the window between `mount/1` and `update/2`, so they
      # derive from `Timezones.fallback/0` rather than spelling their own UTC.
      user_timezone: Timezones.fallback(),
      timezone_display: Timezones.format(Timezones.fallback()),
      timezone_country_code: Timezones.country_code(Timezones.fallback()),
      syncing: false,
      sync_total: 0,
      sync_completed: 0,
      stale_integrations: [],
      oldest_sync_at: nil,
      search_term: "",
      search_results: [],
      search_open: false,
      desktop_reminders_feed: [],
      _initialized: false
    }
  end
end
