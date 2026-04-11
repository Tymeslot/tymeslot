defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud do
  @moduledoc "Public API facade — delegates to EventCreate, EventDelete, and EventRecurrence."

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreate
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventRecurrence

  defdelegate handle_show_create_form(params, socket), to: EventCreate
  defdelegate handle_close_create_form(params, socket), to: EventCreate
  defdelegate handle_update_create_title(params, socket), to: EventCreate
  defdelegate handle_update_create_time(params, socket), to: EventCreate
  defdelegate handle_update_create_integration(params, socket), to: EventCreate
  defdelegate handle_add_create_attendee(params, socket), to: EventCreate
  defdelegate handle_remove_create_attendee(params, socket), to: EventCreate
  defdelegate handle_update_create_attendee_input(params, socket), to: EventCreate
  defdelegate handle_update_create_video(params, socket), to: EventCreate
  defdelegate handle_save_event(params, socket), to: EventCreate
  defdelegate run_create_event(payload), to: EventCreate
  defdelegate run_create_ad_hoc_meeting(params), to: EventCreate
  defdelegate handle_create_result(result, socket), to: EventCreate

  defdelegate handle_request_delete_event(params, socket), to: EventDelete
  defdelegate handle_confirm_delete_event(params, socket), to: EventDelete
  defdelegate run_delete_event(payload), to: EventDelete
  defdelegate handle_delete_result(result, socket), to: EventDelete
  defdelegate handle_cancel_delete_event(params, socket), to: EventDelete

  defdelegate handle_confirm_recurrence_scope(params, socket), to: EventRecurrence
  defdelegate handle_cancel_recurrence_prompt(params, socket), to: EventRecurrence
end
