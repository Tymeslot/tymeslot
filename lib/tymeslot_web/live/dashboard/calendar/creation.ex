defmodule TymeslotWeb.Dashboard.Calendar.Creation do
  @moduledoc """
  Creating events from the calendar surface.

  The hook draws the draft and its quick-create popover, and on save sends
  `calendar:create` with the fields it parsed and its draft id (`create/2`).
  Nothing in it is trusted: the fields are checked again in the domain
  (`CreateParams.cast/4`), and a refusal is answered in the reply, with the
  field and the reason, so the popover stays open beside it. An accepted
  draft is written in a supervised task (`Changes.create_event/2`) and held
  in `pending_creates`, drawn as "Saving…", until `{:calendar_create_result,
  draft, result}` comes back through `CalendarRouting` (`settled/3`). The
  provider gives the event its identity, so nothing stands in for it before
  then.

  A created event nobody was invited to can be undone like any other change:
  it is removed at once (`undo/2`), since nobody has been told about it. One
  whose guests were invited cannot, as the invitations are on their way, so
  its toast offers no Undo and the stack gets no entry.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.CalendarGrid.WriteTask
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Helpers.LocaleFormat

  @type socket :: Phoenix.LiveView.Socket.t()
  @type reply ::
          %{accepted: true} | %{accepted: false, field: String.t() | nil, error: String.t()}

  # What the task answers if the create raises: the draft goes and the
  # organiser is told it failed, rather than "Saving…" staying forever.
  @crashed {:error, %{reason: :crashed, retry: :not_queued}}

  # The hook's draft ids ("d3", "dk2f"); anything else is refused before it is
  # used as a key or sent back in a push.
  @draft_id ~r/\Ad[0-9a-z]{1,31}\z/

  @doc "Whether `id` is a draft id the hook could have made."
  @spec draft_id?(term()) :: boolean()
  def draft_id?(id), do: is_binary(id) and Regex.match?(@draft_id, id)

  @doc """
  A draft the hook asks to save. Returns the reply for the hook and the
  socket: the draft pending and pushed as saving, or unchanged after a
  refusal. The same draft id sent again while it is saving is accepted
  without a second create.
  """
  @spec create(socket(), map()) :: {reply(), socket()}
  def create(socket, %{"draft" => draft} = params) when is_binary(draft) do
    cond do
      not draft_id?(draft) -> {refused(:params, :invalid), socket}
      Map.has_key?(socket.assigns.pending_creates, draft) -> {%{accepted: true}, socket}
      true -> cast_and_start(socket, draft, params)
    end
  end

  def create(socket, _params), do: {refused(:params, :invalid), socket}

  defp cast_and_start(socket, draft, params) do
    %{current_user: user, integrations: integrations, timezone: timezone} = socket.assigns

    with {:ok, create} <- CreateParams.cast(user.id, integrations, titled(params), timezone),
         {:ok, socket} <- start(socket, draft, create) do
      {%{accepted: true}, SurfaceData.push_events(socket, false)}
    else
      {:error, :rate_limited, _message} = refusal ->
        {_level, message} = CalendarEditMessages.refusal(refusal)
        {%{accepted: false, field: nil, error: message}, socket}

      {:error, field, reason} ->
        {refused(field, reason), socket}
    end
  end

  # An untitled draft is created under the name the popover showed it with.
  defp titled(params) do
    case params["title"] do
      title when is_binary(title) ->
        if String.trim(title) == "", do: Map.put(params, "title", new_event()), else: params

      nil ->
        Map.put(params, "title", new_event())

      _not_text ->
        params
    end
  end

  defp new_event, do: dgettext("dashboard_calendar", "New event")

  @doc """
  Starts writing `params` for the draft `draft`, within the calendar edit
  rate limit (a create can email guests, and is always a provider write).
  """
  @spec start(socket(), String.t(), CreateParams.t()) ::
          {:ok, socket()} | {:error, :rate_limited, String.t()}
  def start(socket, draft, %CreateParams{} = params) when is_binary(draft) do
    user_id = socket.assigns.current_user.id

    with :ok <- EditGuard.rate_limit(user_id) do
      :ok =
        WriteTask.start(
          {:calendar_create_result, draft},
          fn -> Changes.create_event(user_id, params) end,
          @crashed
        )

      {:ok,
       assign(socket, :pending_creates, Map.put(socket.assigns.pending_creates, draft, params))}
    end
  end

  @doc """
  The create for `draft` has answered. The toast names the result only for a
  draft this surface is holding: a create a surface mounted before this one
  started is reloaded into view and nothing more.
  """
  @spec settled(socket(), String.t(), term()) :: socket()
  def settled(socket, draft, result) do
    {params, pending} = Map.pop(socket.assigns.pending_creates, draft)

    socket
    |> assign(:pending_creates, pending)
    |> settle(draft, params, result)
  end

  defp settle(socket, _draft, params, {:ok, created}),
    do: socket |> SurfaceData.reload(:events) |> announce(params, created)

  # A queued CalDAV create is tagged in the cache by the offline queue, so the
  # reload shows it waiting to sync; it cannot be undone from here.
  defp settle(socket, draft, params, {:error, %{retry: :queued}}) do
    socket
    |> push_event("calendar:draft-cleared", %{draft: draft})
    |> SurfaceData.reload(:events)
    |> toast(params, fn params ->
      dgettext(
        "dashboard_calendar",
        "“%{title}” is saved here and will reach your calendar at its next sync.",
        title: params.title
      )
    end)
  end

  defp settle(socket, draft, params, {:error, failure}) do
    socket
    |> push_event("calendar:draft-cleared", %{draft: draft})
    |> SurfaceData.push_events(false)
    |> toast(params, fn params ->
      dgettext("dashboard_calendar", "Couldn't add “%{title}”. %{reason}",
        title: params.title,
        reason: CalendarEditMessages.create_failure_reason(Map.get(failure, :reason))
      )
    end)
  end

  defp toast(socket, nil, _text), do: socket
  defp toast(socket, params, text), do: Toast.show(socket, text.(params))

  defp announce(socket, nil, _created), do: socket

  defp announce(socket, params, %{event: event, invited: []}) do
    case undo_entry(event, params) do
      nil ->
        Toast.show(socket, added_text(socket, params))

      entry ->
        socket
        |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
        |> Toast.show(added_text(socket, params), undo: true, key: entry.key)
    end
  end

  defp announce(socket, _params, %{invited: invited}) do
    Toast.show(
      socket,
      dngettext(
        "dashboard_calendar",
        "Added and invited %{count} guest",
        "Added and invited %{count} guests",
        length(invited)
      )
    )
  end

  # A row the cache refused (incomplete timing) cannot be found again, so
  # there is nothing to undo; nor is there for a repeating event, as no
  # series-wide change can be undone here.
  defp undo_entry(nil, _params), do: nil
  defp undo_entry(_event, %CreateParams{recurrence_rule: rule}) when is_binary(rule), do: nil

  defp undo_entry(event, params),
    do: %{
      kind: :create,
      key: WriteQueue.key(event),
      id: EventPayload.id(event),
      title: params.title
    }

  defp added_text(socket, params),
    do: dgettext("dashboard_calendar", "Added: %{when}", when: when_text(socket, params))

  defp when_text(_socket, %CreateParams{all_day: true, start_at: %Date{} = day}),
    do: LocaleFormat.format_short_weekday_date(day, Gettext.get_locale(TymeslotWeb.Gettext))

  defp when_text(socket, %CreateParams{start_at: start_at}),
    do: Manipulation.when_text(socket, start_at)

  @doc """
  Undoes a create: the event is removed at once and nobody is told (see
  `Deletion.remove_created/2`). An event no longer in the loaded window was
  deleted or synced away meanwhile, so it is too late; a refusal that may
  pass (the rate limit, a write still saving) leaves the change on the stack.
  """
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :create} = entry) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, entry.id),
         :ok <- EditGuard.check(user.id, integrations, event),
         false <- Writes.saving?(socket, event) do
      Deletion.remove_created(socket, event)
    else
      :error ->
        Deletion.too_late(socket, %{kind: :gone, title: entry.title})

      true ->
        socket
        |> keep(entry)
        |> flash(
          {:warning,
           dgettext("dashboard_calendar", "This event is still saving. Undo once it has saved.")}
        )

      {:error, :rate_limited, _message} = refusal ->
        socket |> keep(entry) |> flash(CalendarEditMessages.refusal(refusal))

      refusal ->
        flash(socket, CalendarEditMessages.refusal(refusal))
    end
  end

  defp keep(socket, entry), do: assign(socket, :undo, UndoStack.push(socket.assigns.undo, entry))

  defp flash(socket, message) do
    send(self(), {:flash, message})
    socket
  end

  defp refused(field, reason) do
    %{
      accepted: false,
      field: if(field == :params, do: nil, else: Atom.to_string(field)),
      error: refusal_message(field, reason)
    }
  end

  @doc """
  What a refusal from `CreateParams.cast/4` says, for the field it names.
  The side panel's "New event" state shows the same words.
  """
  @spec refusal_message(CreateParams.field(), atom()) :: String.t()
  def refusal_message(:title, :blank),
    do: dgettext("dashboard_calendar", "Give the event a title.")

  def refusal_message(:title, :too_long),
    do: dgettext("dashboard_calendar", "The title is too long. Keep it under 500 characters.")

  def refusal_message(:title, _invalid),
    do: dgettext("dashboard_calendar", "The title contains characters that can't be saved.")

  def refusal_message(:start, :out_of_range),
    do: dgettext("dashboard_calendar", "Pick a date between 1900 and 2200.")

  def refusal_message(field, :invalid) when field in [:start, :end],
    do: dgettext("dashboard_calendar", "That date or time can't be read.")

  def refusal_message(:end, :before_start),
    do: dgettext("dashboard_calendar", "The event must end after it starts.")

  def refusal_message(:end, :longer_than_a_week),
    do: dgettext("dashboard_calendar", "An event with times can last at most 7 days.")

  def refusal_message(:end, :longer_than_a_year),
    do: dgettext("dashboard_calendar", "An all-day event can last at most a year.")

  def refusal_message(:calendar, :read_only),
    do: dgettext("dashboard_calendar", "That calendar is read-only. Choose another one.")

  def refusal_message(:calendar, _not_found),
    do: dgettext("dashboard_calendar", "Choose one of your calendars.")

  def refusal_message(:location, :too_long),
    do: dgettext("dashboard_calendar", "The place is too long. Keep it under 1,000 characters.")

  def refusal_message(:description, :too_long),
    do:
      dgettext("dashboard_calendar", "The notes are too long. Keep them under 5,000 characters.")

  def refusal_message(field, _invalid) when field in [:location, :description],
    do: dgettext("dashboard_calendar", "That text contains characters that can't be saved.")

  def refusal_message(:guests, :too_many),
    do: dgettext("dashboard_calendar", "You can invite at most 50 guests at once.")

  def refusal_message(:guests, _invalid),
    do: dgettext("dashboard_calendar", "One of the guest addresses isn't a valid email address.")

  def refusal_message(:reminders, _invalid),
    do: dgettext("dashboard_calendar", "Those reminders can't be saved.")

  def refusal_message(:recurrence_rule, :not_repeatable),
    do: dgettext("dashboard_calendar", "Events on that calendar can't repeat.")

  def refusal_message(:recurrence_rule, _invalid),
    do: dgettext("dashboard_calendar", "That repeat rule can't be read.")

  def refusal_message(:video_integration_id, _invalid),
    do: dgettext("dashboard_calendar", "That video call can't be added.")

  def refusal_message(_field, _reason),
    do: dgettext("dashboard_calendar", "Couldn't add the event. Please try again.")
end
