defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.FixedDatesSection do
  @moduledoc """
  Stateless function component for the meeting-type form's fixed dates
  (`Tymeslot.MeetingTypes.FixedDates`), shown under group bookings.

  A toggle switches the type from the times its availability schedule
  offers to the dates its host plans. While upcoming dates are planned it
  cannot be turned off: they would stay on the calendar and in people's
  diaries with nothing on the booking page to explain them, so the host
  cancels them first.

  Below it the planned dates, each with its seats and when registration
  closes, and a row to plan another: a date, a time and an optional close
  of registration, all in the host's own time zone. An upcoming date is
  edited in place: moving it takes everyone booked on it along and tells
  them, and its registration close can move at any time up to its start.
  Cancelling a date with people booked on it asks first, and tells them
  through the same cancel path a group meeting always uses. Dates can only be planned on a saved
  type, since each one is a meeting of it.

  Events go to the parent `MeetingTypeForm` (`@myself`), which hands them to
  `SessionHandlers`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :fixed_dates, :boolean, required: true
  attr :is_edit, :boolean, required: true
  attr :sessions, :list, default: [], doc: "`SessionHandlers.rows/1`"
  attr :timezone, :string, required: true
  attr :new_session, :map, default: %{}
  attr :session_error, :string, default: nil
  attr :confirming_session_id, :string, default: nil

  attr :editing_session, :map,
    default: nil,
    doc: "the date being edited: `%{id, input, error}`, `input` as the form posts it"

  attr :form_id, :string, required: true
  attr :myself, :any, required: true

  @spec fixed_dates_section(map()) :: Phoenix.LiveView.Rendered.t()
  def fixed_dates_section(assigns) do
    assigns = assign(assigns, :upcoming?, Enum.any?(assigns.sessions, &(not &1.past?)))

    ~H"""
    <section class="space-y-4" data-testid="fixed-dates-section">
      <.setting_row
        id={"fixed-dates-toggle-#{@form_id}"}
        label={dgettext("dashboard_meeting_form", "Offer fixed dates only")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Instead of times from the availability schedule, bookers choose from the dates you plan. Each date is on your calendar at once."
          )
        }
        checked={@fixed_dates}
        disabled={@fixed_dates and @upcoming?}
        on_change="toggle_fixed_dates"
        target={@myself}
      >
        <:disabled_reason>
          {dgettext("dashboard_meeting_form", "Cancel the planned dates to turn this off.")}
        </:disabled_reason>
      </.setting_row>

      <p
        :if={@fixed_dates and not @is_edit}
        class="text-token-sm text-tymeslot-600"
        data-testid="fixed-dates-create-first"
      >
        {dgettext("dashboard_meeting_form", "Create the meeting type to plan its dates.")}
      </p>

      <div :if={@fixed_dates and @is_edit} class="space-y-3">
        <p class="text-token-sm text-tymeslot-600">
          {dgettext("dashboard_meeting_form", "Times are in your time zone, %{timezone}.",
            timezone: @timezone
          )}
        </p>

        <p
          :if={@sessions == []}
          class="text-token-sm text-tymeslot-500 italic"
          data-testid="no-sessions"
        >
          {dgettext("dashboard_meeting_form", "No dates planned yet.")}
        </p>

        <ul :if={@sessions != []} class="space-y-2">
          <li
            :for={session <- @sessions}
            class={[
              "flex flex-wrap items-center gap-x-3 gap-y-1 rounded-token-xl border border-tymeslot-100 bg-white px-3 py-2 text-token-sm",
              session.past? && "opacity-60"
            ]}
            data-testid="planned-session"
          >
            <span class="font-semibold text-tymeslot-800">
              {LocalizationHelpers.format_meeting_datetime(session.start_time, @timezone)}
            </span>
            <span class="text-tymeslot-600">
              {dgettext("dashboard_meeting_form", "%{taken} of %{capacity} seats taken",
                taken: session.seats_taken,
                capacity: session.capacity
              )}
            </span>
            <span
              :if={session.registration_closes_at && session.open?}
              class="text-tymeslot-600"
            >
              {dgettext("dashboard_meeting_form", "registration until %{datetime}",
                datetime:
                  LocalizationHelpers.format_meeting_datetime(
                    session.registration_closes_at,
                    @timezone
                  )
              )}
            </span>
            <span
              :if={not session.past? and not session.open?}
              class="font-medium text-amber-700"
              data-testid="session-registration-closed"
            >
              {dgettext("dashboard_meeting_form", "registration closed")}
            </span>

            <%= cond do %>
              <% session.past? -> %>
              <% @editing_session && @editing_session.id == session.id -> %>
                <.session_editor session={session} editing={@editing_session} myself={@myself} />
              <% @confirming_session_id == session.id -> %>
                <span class="w-full text-token-sm text-red-700" role="alert">
                  {dngettext(
                    "dashboard_meeting_form",
                    "Cancel this date? %{count} person is booked and will be told.",
                    "Cancel this date? %{count} people are booked and will be told.",
                    session.participants,
                    count: session.participants
                  )}
                </span>
                <.action_button
                  size={:sm}
                  variant={:danger}
                  phx-click="cancel_session"
                  phx-value-id={session.id}
                  phx-target={@myself}
                  data-testid="confirm-cancel-session"
                >
                  {dgettext("dashboard_meeting_form", "Cancel date")}
                </.action_button>
                <.action_button
                  size={:sm}
                  variant={:ghost}
                  phx-click="keep_session"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_meeting_form", "Keep it")}
                </.action_button>
              <% true -> %>
                <button
                  type="button"
                  class="ml-auto inline-flex h-8 w-8 items-center justify-center rounded-token-full border border-tymeslot-200 bg-white text-tymeslot-500 hover:text-turquoise-700 hover:border-turquoise-300"
                  phx-click="edit_session"
                  phx-value-id={session.id}
                  phx-target={@myself}
                  aria-label={dgettext("dashboard_meeting_form", "Edit this date")}
                  title={dgettext("dashboard_meeting_form", "Edit this date")}
                  data-testid="edit-session-button"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  class="inline-flex h-8 w-8 items-center justify-center rounded-token-full border border-tymeslot-200 bg-white text-tymeslot-500 hover:text-red-600 hover:border-red-300"
                  phx-click="remove_session"
                  phx-value-id={session.id}
                  phx-target={@myself}
                  aria-label={dgettext("dashboard_meeting_form", "Cancel this date")}
                  title={dgettext("dashboard_meeting_form", "Cancel this date")}
                  data-testid="remove-session"
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </button>
            <% end %>
          </li>
        </ul>

        <div class="flex flex-wrap items-end gap-3" data-testid="new-session">
          <.input
            type="date"
            id={"new-session-date-#{@form_id}"}
            name="session[date]"
            label={dgettext("dashboard_meeting_form", "Date")}
            value={Map.get(@new_session, "date", "")}
            phx-change="update_session_input"
            phx-target={@myself}
          />
          <.input
            type="time"
            id={"new-session-time-#{@form_id}"}
            name="session[time]"
            label={dgettext("dashboard_meeting_form", "Time")}
            value={Map.get(@new_session, "time", "")}
            phx-change="update_session_input"
            phx-target={@myself}
          />
          <.input
            type="datetime-local"
            id={"new-session-closes-#{@form_id}"}
            name="session[closes_at]"
            label={dgettext("dashboard_meeting_form", "Registration closes (optional)")}
            value={Map.get(@new_session, "closes_at", "")}
            phx-change="update_session_input"
            phx-target={@myself}
          />
          <.action_button
            size={:sm}
            phx-click="add_session"
            phx-target={@myself}
            data-testid="add-session"
          >
            {dgettext("dashboard_meeting_form", "Add date")}
          </.action_button>
        </div>
        <p :if={@session_error} class="form-error" data-testid="session-error">
          {@session_error}
        </p>
      </div>
    </section>
    """
  end

  attr :session, :map, required: true
  attr :editing, :map, required: true
  attr :myself, :any, required: true

  # One planned date opened for editing: its date, time and registration
  # close, saved together. Moving it tells everyone booked on it.
  defp session_editor(assigns) do
    ~H"""
    <div class="flex w-full flex-wrap items-end gap-2" data-testid="edit-session">
      <.input
        :for={
          {field, type, label} <- [
            {"date", "date", dgettext("dashboard_meeting_form", "Date")},
            {"time", "time", dgettext("dashboard_meeting_form", "Time")},
            {"closes_at", "datetime-local", dgettext("dashboard_meeting_form", "Registration closes")}
          ]
        }
        type={type}
        id={"edit-session-#{field}-#{@session.id}"}
        name={"session_edit[#{field}]"}
        label={label}
        value={@editing.input[field]}
        phx-change="update_session_edit"
        phx-target={@myself}
      />
      <.action_button
        size={:sm}
        phx-click="save_session_edit"
        phx-target={@myself}
        data-testid="save-session-edit"
      >
        {dgettext("dashboard_meeting_form", "Save")}
      </.action_button>
      <.action_button
        size={:sm}
        variant={:ghost}
        phx-click="discard_session_edit"
        phx-target={@myself}
      >
        {dgettext("dashboard_meeting_form", "Cancel")}
      </.action_button>
      <p class="w-full text-token-xs text-tymeslot-500">
        {dgettext(
          "dashboard_meeting_form",
          "Leave the registration close empty to take sign-ups until the start. A time already past closes registration now."
        )}
        <span :if={@session.participants > 0}>
          {dngettext(
            "dashboard_meeting_form",
            "Moving the date emails the %{count} person booked on it the new time.",
            "Moving the date emails the %{count} people booked on it the new time.",
            @session.participants,
            count: @session.participants
          )}
        </span>
      </p>
      <p :if={@editing.error} class="form-error w-full" role="alert">{@editing.error}</p>
    </div>
    """
  end
end
