defmodule TymeslotWeb.Dashboard.MeetingFormMessages do
  @moduledoc """
  Routes form-related `handle_info/2` messages back into `MeetingTypeForm`.

  Child LiveComponents (`CustomQuestionsSection`, `QuestionEditorComponent`,
  the reminder editor, the calendar picker) use `send(self(), …)` to bubble
  intent up to `DashboardLive`, which owns the LiveView process. The functions
  in this module take the parsed payload and push new assigns back to the
  correct `MeetingTypeForm` instance via `send_update/2`.

  Children compute derived state locally (e.g. the new ordered list after a
  delete) and send the completed result — not the raw intent — so this module
  never needs to read component assigns.
  """

  import Phoenix.LiveView, only: [send_update: 2]

  alias Ecto.UUID
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm

  @doc "Opens the question editor for a new custom question."
  @spec handle_open_add(String.t(), list(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_open_add(form_id, current_fields, socket) do
    empty = %FieldDefinition{
      id: UUID.generate(),
      type: "short_text",
      position: length(current_fields)
    }

    send_update(MeetingTypeForm, id: form_id, editing_question: empty)
    {:noreply, socket}
  end

  @doc "Opens the question editor populated with an existing question."
  @spec handle_open_edit(FieldDefinition.t(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_open_edit(question, form_id, socket) do
    send_update(MeetingTypeForm, id: form_id, editing_question: question)
    {:noreply, socket}
  end

  @doc "Closes the question editor without saving."
  @spec handle_cancel(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel(form_id, socket) do
    send_update(MeetingTypeForm, id: form_id, editing_question: nil)
    {:noreply, socket}
  end

  @doc "Replaces the custom-fields list on the form after an add/edit/delete/reorder."
  @spec handle_fields_updated(list(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_fields_updated(updated_fields, form_id, socket) do
    send_update(MeetingTypeForm,
      id: form_id,
      custom_fields: updated_fields,
      editing_question: nil
    )

    {:noreply, socket}
  end

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
end
