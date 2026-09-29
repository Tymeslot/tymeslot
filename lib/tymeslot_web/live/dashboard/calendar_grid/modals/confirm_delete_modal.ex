defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModal do
  @moduledoc """
  Confirmation modal for deleting a calendar event.

  `scopes` is what `Tymeslot.CalendarGrid.deletion_scopes/1` answered for the
  event: a single event gets one Delete button, and a member of a series gets
  the choice between its one occurrence and the whole series, sent as the
  `scope` value of `confirm_delete_event`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :event, :map, required: true
  attr :scopes, :atom, values: [:single, :series], default: :single
  attr :deleting, :boolean, default: false
  attr :linked_to_booking, :boolean, default: false
  attr :myself, :any, required: true

  @spec confirm_delete_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_delete_modal(assigns) do
    assigns =
      assign(
        assigns,
        :title,
        assigns.event.summary || dgettext("dashboard_calendar_events", "(No title)")
      )

    ~H"""
    <.modal
      id="confirm-delete-event-modal"
      show={true}
      on_cancel={JS.push("cancel_delete_event", target: @myself)}
      size={:small}
    >
      <:header>
        {if @scopes == :series,
          do: dgettext("dashboard_calendar_events", "Delete recurring event"),
          else: dgettext("dashboard_calendar_events", "Delete event")}
      </:header>

      <p :if={@scopes == :single} class="text-token-sm text-tymeslot-500">
        {dgettext("dashboard_calendar_events", "Are you sure you want to delete %{title}?",
          title: @title
        )}
        {dgettext(
          "dashboard_calendar_events",
          "This will also remove it from your calendar provider."
        )}
      </p>
      <p :if={@scopes == :series} class="text-token-sm text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_events",
          "%{title} is part of a repeating series. Do you want to delete only this event, or every event in the series?",
          title: @title
        )}
        {dgettext(
          "dashboard_calendar_events",
          "Deleted events are also removed from your calendar provider."
        )}
      </p>
      <p :if={@linked_to_booking} class="mt-2 text-token-sm text-amber-600">
        {dgettext(
          "dashboard_calendar_events",
          "This event is linked to a booking. The attendee will be notified of the cancellation."
        )}
      </p>

      <:footer>
        <div class="flex flex-wrap gap-2">
          <.loading_button
            :if={@scopes == :single}
            variant={:danger}
            loading={@deleting}
            loading_text={dgettext("dashboard_calendar_events", "Deleting...")}
            phx-click="confirm_delete_event"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Delete")}
          </.loading_button>
          <.loading_button
            :if={@scopes == :series}
            variant={:danger}
            loading={@deleting}
            loading_text={dgettext("dashboard_calendar_events", "Deleting...")}
            phx-click="confirm_delete_event"
            phx-value-scope="occurrence"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Delete this event")}
          </.loading_button>
          <.loading_button
            :if={@scopes == :series}
            variant={:danger}
            loading={@deleting}
            loading_text={dgettext("dashboard_calendar_events", "Deleting...")}
            phx-click="confirm_delete_event"
            phx-value-scope="series"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Delete all events")}
          </.loading_button>
          <.action_button
            variant={:secondary}
            disabled={@deleting}
            phx-click={JS.push("cancel_delete_event", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
