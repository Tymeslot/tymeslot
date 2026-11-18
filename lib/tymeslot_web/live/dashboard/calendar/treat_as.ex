defmodule TymeslotWeb.Dashboard.Calendar.TreatAs do
  @moduledoc """
  The preview's "Treat as Busy | Free" for an all-day event on a read-only
  calendar (a holiday from a feed, a colleague's away day): a choice kept in
  Tymeslot that decides whether guests can book that day, and never changes
  the calendar. On a calendar Tymeslot can write to, the preview's own
  "Show as Busy | Free" changes the event itself, which bookings follow, so
  this control is not offered there.

  Without a choice, such an event counts for bookings exactly as its
  calendar marks it (`Tymeslot.Availability.Bookability`); the control
  shows that default until a choice is stored. The button that matches the
  default clears the choice and the other stores it. It is offered only
  where it can matter: an all-day event on a read-only calendar that blocks
  bookings.
  A choice sent for anything else is ignored.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventBlocking
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar.Selection
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @typedoc """
  Whether the event is busy for bookings now and by the rule alone, and
  whether a choice for it covers every time its series repeats (choices are
  kept by uid, which a CalDAV series shares).
  """
  @type state :: %{busy: boolean(), default: boolean(), every_repeat: boolean()}

  @doc """
  The control's state for `event`, or nil where it is not offered.
  `blocks?` says whether the event's calendar blocks bookings; `context` is
  `Preview.context/1`'s, whose `bookability` holds the stored choices.
  """
  @spec state(map(), boolean(), map()) :: state() | nil
  def state(%{kind: :booking}, _blocks?, _context), do: nil

  def state(%{all_day: true} = event, true, context) do
    integration =
      Enum.find(context.integrations, &(&1.id == Map.get(event, :calendar_integration_id)))

    # The engine's own rule, so the preview and the booking page agree: a
    # cancelled event reads Free until the organiser says otherwise.
    if integration && not Selection.event_writable?(event, integration) do
      %{
        busy:
          EventBlocking.busy_for_bookings?(
            event,
            integration,
            Map.get(context, :bookability, %{})
          ),
        default: EventBlocking.blocks?(event, integration),
        every_repeat: Occurrence.uid_shared_by_series?(event)
      }
    end
  end

  def state(_event, _blocks?, _context), do: nil

  @doc """
  Applies the choice `choice` ("default", "true" or "false") to the loaded
  event `id`, within the calendar edit rate limit, and rebuilds the preview.
  "default" clears the stored choice, so the event follows the rule again.
  """
  @spec set(Phoenix.LiveView.Socket.t(), String.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def set(socket, id, choice) do
    user_id = socket.assigns.current_user.id

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         %{treat_as: %{default: default, every_repeat: every_repeat}} <-
           Preview.build(event, Preview.context(socket.assigns)),
         :ok <- EditGuard.rate_limit(user_id) do
      busy = if choice == "default", do: default, else: choice == "true"

      if saved?(write(user_id, event, choice)) do
        socket
        |> assign(:bookability, Bookability.for_user(user_id))
        # Rebuilds the open preview from the new choice.
        |> SurfaceData.refilter()
        |> Toast.show(toast_text(busy, every_repeat))
      else
        flash(
          socket,
          {:error,
           dgettext("dashboard_calendar_booking", "Couldn't change that. Please try again.")}
        )
      end
    else
      {:error, :rate_limited, _message} = refusal ->
        flash(socket, CalendarEditMessages.refusal(refusal))

      _not_offered ->
        socket
    end
  end

  defp write(user_id, event, "default"),
    do: Bookability.clear(user_id, event.calendar_integration_id, event.uid)

  defp write(user_id, event, choice),
    do: Bookability.set(user_id, event.calendar_integration_id, event.uid, choice == "true")

  # `Bookability.set/4` and `clear/3` answer `:ok | {:error, reason}`.
  defp saved?(:ok), do: true
  defp saved?({:error, _reason}), do: false

  defp toast_text(false, false),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Treated as free for bookings. Guests can book this time."
      )

  defp toast_text(true, false),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Treated as busy for bookings. Guests can't book this time."
      )

  defp toast_text(false, true),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Treated as free for bookings every time this repeats. Guests can book those times."
      )

  defp toast_text(true, true),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Treated as busy for bookings every time this repeats. Guests can't book those times."
      )

  defp flash(socket, message) do
    send(self(), {:flash, message})
    socket
  end

  attr :preview, :map, required: true
  attr :target, :any, required: true

  @doc "The control, in the preview's availability row."
  @spec control(map()) :: Phoenix.LiveView.Rendered.t()
  def control(assigns) do
    ~H"""
    <div id="calendar-preview-treat-as" class="space-y-1">
      <div class="flex flex-wrap items-center gap-2">
        <span id="calendar-preview-treat-as-label" class="font-semibold">
          {dgettext("dashboard_calendar_booking", "Treat as")}
        </span>
        <div
          class="inline-flex rounded-token-lg border border-tymeslot-200 p-0.5"
          role="group"
          aria-labelledby="calendar-preview-treat-as-label"
        >
          <button
            :for={{busy, id, choice, label} <- choices(@preview.treat_as.default)}
            id={id}
            type="button"
            aria-pressed={to_string(@preview.treat_as.busy == busy)}
            phx-click="calendar:bookability"
            phx-value-id={@preview.id}
            phx-value-busy={choice}
            phx-target={@target}
            class={[
              "rounded-token-md min-h-8 px-2.5 py-1 text-token-sm focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
              if(@preview.treat_as.busy == busy,
                do: "bg-turquoise-50 font-semibold text-turquoise-800",
                else: "text-tymeslot-600 hover:bg-tymeslot-50"
              )
            ]}
          >
            {label}
          </button>
        </div>
        <span>{note(@preview.treat_as.busy)}</span>
      </div>
      <p class="text-token-xs text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_booking",
          "Affects Tymeslot bookings only. Your calendar doesn't change."
        )}
      </p>
    </div>
    """
  end

  # The button for the rule's own answer clears the choice; the other
  # stores it.
  defp choices(default),
    do: [
      {true, "calendar-preview-treat-busy", choice(true, default),
       dgettext("dashboard_calendar", "Busy")},
      {false, "calendar-preview-treat-free", choice(false, default),
       dgettext("dashboard_calendar", "Free")}
    ]

  defp choice(default, default), do: "default"
  defp choice(busy, _default), do: to_string(busy)

  defp note(true), do: dgettext("dashboard_calendar", "Guests can't book this time")
  defp note(false), do: dgettext("dashboard_calendar", "Guests can book this time")
end
