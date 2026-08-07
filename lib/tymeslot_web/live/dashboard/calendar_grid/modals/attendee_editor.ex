defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.AttendeeEditor do
  @moduledoc """
  Attendee list and editor for the calendar event detail modal.

  Renders one of two faces depending on `editable`. In edit mode the invited
  attendees show as removable turquoise tags, attendees added but not yet sent
  show as amber dashed tags, and an email form appends to the pending set. In
  read-only mode it lists the first five attendees and summarises the rest.

  The two sets are deliberately distinct: an invited attendee has already had a
  calendar invitation sent on their behalf, so removing one dispatches
  `request_remove_attendee` for the owner to confirm, while a pending one has
  not been sent anything yet and is dropped outright with
  `remove_pending_attendee`. Add/remove and input events all dispatch back to
  the owning LiveComponent via `phx-target`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :editable, :boolean, default: false
  attr :attendees, :list, default: []
  attr :read_only_attendees, :list, default: []
  attr :pending_attendees, :list, default: []
  attr :attendee_input, :string, default: ""
  attr :myself, :any, required: true

  @spec attendee_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def attendee_editor(assigns) do
    ~H"""
    <div :if={@editable or not Enum.empty?(@attendees)} class="flex items-start gap-3 mb-3">
      <svg
        class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
        title={dgettext("dashboard_calendar_events", "Attendees")}
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z"
        />
      </svg>
      <div class="flex-1">
        <%!-- Editable attendee tags --%>
        <div :if={@editable}>
          <div
            :if={@attendees != [] or @pending_attendees != []}
            class="flex flex-wrap gap-1.5 mb-2"
          >
            <%!-- Existing (invited) attendees — turquoise --%>
            <span
              :for={attendee <- @attendees}
              class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-turquoise-50 border border-turquoise-200 text-token-xs text-turquoise-800"
            >
              {attendee["name"] || attendee["email"] || attendee[:email]}
              <button
                type="button"
                phx-click="request_remove_attendee"
                phx-value-email={attendee["email"] || attendee[:email]}
                phx-target={@myself}
                class="w-4 h-4 rounded-full hover:bg-red-100 flex items-center justify-center transition-colors"
                aria-label={
                  dgettext("dashboard_calendar_events", "Remove %{email}",
                    email: attendee["email"] || attendee[:email]
                  )
                }
              >
                <svg class="w-2.5 h-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="3"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </span>
            <%!-- Pending (unsent) attendees — amber dashed --%>
            <span
              :for={email <- @pending_attendees}
              class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-amber-50 border border-dashed border-amber-300 text-token-xs text-amber-800"
            >
              {email}
              <button
                type="button"
                phx-click="remove_pending_attendee"
                phx-value-email={email}
                phx-target={@myself}
                class="w-4 h-4 rounded-full hover:bg-amber-200 flex items-center justify-center transition-colors"
                aria-label={dgettext("dashboard_calendar_events", "Remove %{email}", email: email)}
              >
                <svg class="w-2.5 h-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="3"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </span>
          </div>
          <form
            id="event-add-attendee-form"
            phx-submit="add_event_attendee"
            phx-target={@myself}
            class="flex gap-2"
          >
            <input
              type="email"
              id="edit-attendee-email"
              name="email"
              value={@attendee_input}
              phx-change="update_attendee_input"
              phx-target={@myself}
              placeholder="attendee@example.com"
              class="flex-1 bg-transparent border-0 border-b border-transparent hover:border-tymeslot-300 focus:border-turquoise-500 focus:ring-0 text-token-sm text-tymeslot-600 px-0 py-0 placeholder:text-tymeslot-400 transition-colors cursor-text"
            />
            <button
              type="submit"
              class="px-2 py-0.5 rounded-md border border-tymeslot-200 text-token-xs text-tymeslot-500 hover:bg-tymeslot-50 transition-colors"
            >
              {dgettext("dashboard_calendar_events", "Add")}
            </button>
          </form>
          <p :if={@pending_attendees == []} class="text-token-xs text-tymeslot-400 mt-1">
            {dgettext(
              "dashboard_calendar_events",
              "Each person will receive an invitation from your calendar provider."
            )}
          </p>
        </div>
        <%!-- Read-only attendee display --%>
        <div :if={!@editable}>
          <div
            :for={attendee <- Enum.take(@read_only_attendees, 5)}
            class="text-token-sm text-tymeslot-700 leading-snug"
          >
            {attendee["name"] || attendee["email"]}
            <span
              :if={attendee["name"] && attendee["email"] && attendee["name"] != attendee["email"]}
              class="text-token-xs text-tymeslot-400 ml-1"
            >{attendee["email"]}</span>
          </div>
          <p :if={length(@read_only_attendees) > 5} class="text-token-xs text-tymeslot-400 mt-1">
            {dngettext(
              "dashboard_calendar_events",
              "+%{count} more",
              "+%{count} more",
              length(@read_only_attendees) - 5
            )}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
