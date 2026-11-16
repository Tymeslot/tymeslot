defmodule TymeslotWeb.Dashboard.Calendar.UndeliveredNotice do
  @moduledoc """
  The notice in an event's preview naming the guests its latest update email
  could not reach (`Tymeslot.CalendarGrid.UndeliveredUpdates`), so the
  organiser can tell them another way, and its Dismiss.

  `for_event/2` reads the addresses as the preview is built; the dismiss
  arrives through `PowerEvents` as `"calendar:dismiss_undelivered"`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.UndeliveredUpdates

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The addresses of the guests of `event` whose latest update email could not
  be delivered. Empty for a booking, whose emails are the booking's own.
  """
  @spec for_event(map(), pos_integer()) :: [String.t()]
  def for_event(%{kind: :booking}, _user_id), do: []

  def for_event(%{calendar_integration_id: integration_id, uid: uid}, user_id)
      when is_integer(integration_id) and is_binary(uid),
      do: UndeliveredUpdates.list_for_event(user_id, integration_id, uid)

  def for_event(_event, _user_id), do: []

  @doc "Clears the notice of the event open in the preview: the organiser has seen it."
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:dismiss_undelivered", _params, socket) do
    with %{id: id} = preview <- socket.assigns[:preview],
         {:ok, %{calendar_integration_id: integration_id, uid: uid}}
         when is_integer(integration_id) and is_binary(uid) <-
           Map.fetch(socket.assigns.events_by_id, id) do
      :ok = UndeliveredUpdates.dismiss(socket.assigns.current_user.id, integration_id, uid)
      {:noreply, assign(socket, :preview, %{preview | undelivered: []})}
    else
      _no_event -> {:noreply, socket}
    end
  end

  attr :emails, :list, required: true
  attr :target, :any, required: true

  @spec notice(map()) :: Phoenix.LiveView.Rendered.t()
  def notice(assigns) do
    ~H"""
    <div
      id="calendar-preview-undelivered"
      role="status"
      class="mt-3 flex items-start gap-2 rounded-token-lg border border-amber-200 bg-amber-50 p-3 text-token-sm text-amber-900"
    >
      <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 h-4 w-4 shrink-0 text-amber-600" />
      <div class="min-w-0 flex-1">
        <p>
          {dngettext(
            "dashboard_calendar_events",
            "The latest update could not be emailed to this guest. Let them know another way.",
            "The latest update could not be emailed to these guests. Let them know another way.",
            length(@emails)
          )}
        </p>
        <ul class="mt-1 break-all font-semibold">
          <li :for={email <- @emails}>{email}</li>
        </ul>
      </div>
      <button
        type="button"
        phx-click="calendar:dismiss_undelivered"
        phx-target={@target}
        class="shrink-0 text-amber-800 underline hover:text-amber-900 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-amber-400 rounded-token-sm"
      >
        {dgettext("dashboard_calendar_events", "Dismiss")}
      </button>
    </div>
    """
  end
end
