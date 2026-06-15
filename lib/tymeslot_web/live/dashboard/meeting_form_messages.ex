defmodule TymeslotWeb.Dashboard.MeetingFormMessages do
  @moduledoc """
  Routes form-related `handle_info/2` messages back into `MeetingTypeForm`.

  Child LiveComponents that need asynchronous work (the reminder editor's
  confirmation timeout, the calendar picker's refresh task) use
  `send(self(), …)` to bubble the completed result up to `DashboardLive`,
  which owns the LiveView process. The functions in this module take that
  payload and push new assigns back to the correct `MeetingTypeForm`
  instance via `send_update/2`.

  Synchronous interactions (the custom-questions builder) call
  `Phoenix.LiveView.send_update/2` directly from their LiveComponent
  instead, so the parent form re-renders on the next tick without an
  intermediate `handle_info` hop — important for keeping LiveViewTest
  helpers like `render_click/1` deterministic.
  """

  import Phoenix.LiveView, only: [send_update: 2]

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm

  @doc "Dismisses a reminder confirmation prompt on the form."
  @spec handle_clear_reminder_confirmation(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_clear_reminder_confirmation(form_id, socket) do
    send_update(MeetingTypeForm,
      id: form_id,
      reminder_confirmation: nil
    )

    {:noreply, socket}
  end

  @doc "Kicks off an async refresh of the available calendars for the form."
  @spec handle_refresh_calendar_list(String.t(), integer(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_refresh_calendar_list(form_id, integration_id, socket) do
    user_id = socket.assigns.current_user.id
    Calendar.refresh_calendar_list_async(integration_id, user_id, form_id)
    {:noreply, socket}
  end

  @doc "Pushes the refreshed calendar list back to the form."
  @spec handle_calendar_list_refreshed(String.t(), list(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_list_refreshed(form_id, calendars, socket) do
    send_update(MeetingTypeForm,
      id: form_id,
      refreshing_calendars: false,
      available_calendars: Selection.selected_calendars(calendars)
    )

    {:noreply, socket}
  end

  @doc """
  Triggers a deferred autosave retry on the form after a rate-limit throttle.

  Sends a `send_update` carrying `trigger_autosave: true`, which `MeetingTypeForm.update/2`
  detects and re-invokes `Autosave.maybe_run/1`. If the rate limit is still
  active the retry simply reschedules itself; once the window clears the save
  proceeds normally.
  """
  @spec handle_retry_autosave(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_retry_autosave(form_id, socket) do
    send_update(MeetingTypeForm, id: form_id, trigger_autosave: true)
    {:noreply, socket}
  end
end
