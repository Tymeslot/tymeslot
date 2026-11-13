defmodule TymeslotWeb.Dashboard.Calendar.PanelNew do
  @moduledoc """
  The side panel's "New event" state, and the edit state's Duplicate and
  Delete.

  "More options" in quick create opens the panel holding what was typed.
  The panel keeps two things: `form`, the string-keyed values as the
  organiser typed them (the create params of
  `Tymeslot.CalendarGrid.CreateParams`), which the form shows, and `draft`,
  the last of them the domain accepted (`CreateParams.cast/4`), which the
  payload draws on the grid under `draft_id`. A change the domain refuses
  (an end before its start) leaves `draft` as it was and puts the reason in
  the header. Nothing is written while the state is open. Create casts the
  form again and runs the create path every create takes
  (`Creation.start/3`); the draft then belongs to the pending create, and
  once that answers the panel edits the new event. With a guest and "Send as a
  Tymeslot meeting" ticked, Create books a Tymeslot meeting instead
  (`PanelMeeting`); with "Group event" ticked, Create makes a one-off event
  people sign up for (`PanelGroupEvent`).

  Duplicate creates a copy of the panel's event at the same time the next
  day through the same path, without its guests (nobody is emailed) or its
  video call (its room is the original's). Delete hands the event to
  `Deletion.request/2` and closes the panel.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.Venues
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.PanelGroupEvent
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @text_fields ~w(title start end calendar location description video_integration_id)

  @doc """
  Opens the panel on the draft `params` describe (`calendar:more_options`).
  Answers whether it opened, for the hook's reply: a draft id the hook could
  not have made, or one whose create is saving or has landed, opens nothing.
  """
  @spec open(socket(), map()) :: {boolean(), socket()}
  def open(socket, %{"draft" => draft_id} = params) when is_binary(draft_id) do
    if Creation.draft_id?(draft_id) and not Creation.taken?(socket, draft_id),
      do: {true, open_draft(socket, draft_id, params)},
      else: {false, socket}
  end

  def open(socket, _params), do: {false, socket}

  defp open_draft(socket, draft_id, params) do
    {guests, guests_status} = typed_guests(socket, params["guests"])

    form =
      params
      |> Map.take(@text_fields)
      |> Map.new(fn {key, value} -> {key, text(value)} end)
      |> Map.merge(%{
        "all_day" => truthy?(params["all_day"]),
        "free" => truthy?(params["free"]),
        "guests" => guests
      })
      |> Map.merge(PanelMeeting.defaults(socket.assigns.current_user))
      |> Map.merge(PanelGroupEvent.defaults())

    {draft, status} = cast(socket, form, nil)
    status = if status == :idle, do: guests_status, else: status

    socket
    |> PanelState.give_way()
    |> assign(
      panel: %{
        mode: :new,
        event_id: nil,
        event: nil,
        draft: draft,
        draft_id: draft_id,
        form: form,
        scope: nil,
        opened_with: nil,
        status: status,
        writes: [],
        errors: %{},
        repeat: %{custom_open: false, draft: nil, version: 0},
        calendar_version: 0,
        video_version: 0,
        venues: group_venues(socket)
      },
      preview: nil,
      open_menu: nil
    )
    |> push_event("calendar:panel", %{open: true})
    |> SurfaceData.push_events(false)
  end

  @doc """
  A change of the New event form: the form takes the fields, the end
  follows a changed start (keeping the length), all day converts the times,
  the draft is cast again and the grid is told.
  """
  @spec change(socket(), map()) :: socket()
  def change(
        %{assigns: %{panel: %{mode: :new, status: status, form: form} = panel}} = socket,
        params
      )
      when status != :saving do
    updated =
      form
      |> Map.merge(form_fields(params, form))
      |> Map.merge(PanelMeeting.fields(params))
      |> Map.merge(PanelGroupEvent.fields(params))
      |> convert_all_day(form)
      |> follow_start(form, params["_target"])

    {draft, status} = cast(socket, updated, panel.draft)

    socket
    |> assign(:panel, %{panel | form: updated, draft: draft, status: status})
    |> SurfaceData.push_events(false)
  end

  def change(socket, _params), do: socket

  @doc """
  The New event form's submit. `intent=add_guest` adds the typed guest to
  the form (an empty field adds nothing, so Enter in another field never
  creates); `intent=create` creates the event.
  """
  @spec submit(socket(), map()) :: socket()
  def submit(
        %{assigns: %{panel: %{mode: :new, status: status}}} = socket,
        %{"intent" => "add_guest"} = params
      )
      when status != :saving do
    socket = change(socket, params)

    case String.trim(params["guest_email"] || "") do
      "" -> socket
      email -> add_guest(socket, email)
    end
  end

  def submit(socket, %{"intent" => "create"} = params), do: socket |> change(params) |> create()
  def submit(socket, _params), do: socket

  @doc "Drops the guest `email` from the form."
  @spec drop_guest(socket(), String.t()) :: socket()
  def drop_guest(
        %{assigns: %{panel: %{mode: :new, status: status, form: form} = panel}} = socket,
        email
      )
      when is_binary(email) and status != :saving do
    form = %{form | "guests" => List.delete(form["guests"], email)}
    {draft, status} = cast(socket, form, panel.draft)

    socket
    |> assign(:panel, %{panel | form: form, draft: draft, status: status})
    |> SurfaceData.push_events(false)
  end

  def drop_guest(socket, _email), do: socket

  @doc "Closes the New event state and drops its draft."
  @spec cancel(socket()) :: socket()
  def cancel(%{assigns: %{panel: %{mode: :new}}} = socket), do: PanelState.close(socket)
  def cancel(socket), do: socket

  @doc """
  The create path answered for the draft `draft_id`: when it is the
  panel's, the panel edits the new event, or says why it was not created
  and draws the draft again.
  """
  @spec settled(socket(), String.t(), term()) :: socket()
  def settled(
        %{assigns: %{panel: %{mode: :new, draft_id: draft_id} = panel}} = socket,
        draft_id,
        result
      ) do
    case result do
      {:ok, %{event: %{} = created}} ->
        socket = PanelState.open_edit(socket, EventPayload.id(created))

        # The reload did not show the row: there is nothing to edit.
        if match?(%{panel: %{mode: :new}}, socket.assigns),
          do: PanelState.close(socket),
          else: socket

      # Created, but the cache refused the row (incomplete timing): there is
      # nothing to edit until the next sync shows it.
      {:ok, _created} ->
        PanelState.close(socket)

      # Saved here and waiting for the calendar to take it: the event exists,
      # so there is no draft to correct.
      {:error, %{retry: :queued}} ->
        PanelState.close(socket)

      {:error, _failure} ->
        {draft, _status} = cast(socket, panel.form, nil)

        socket
        |> assign(:panel, %{
          panel
          | draft: draft,
            status:
              {:failed,
               dgettext(
                 "dashboard_calendar_editing",
                 "The event wasn't created. Check it and try again."
               )}
        })
        |> SurfaceData.push_events(false)
    end
  end

  def settled(socket, _draft_id, _result), do: socket

  @doc """
  Creates a copy of the panel's event at the same time the next day. An
  event that is moving to another calendar is not written to meanwhile.
  """
  @spec duplicate(socket()) :: socket()
  def duplicate(%{assigns: %{panel: %{mode: :edit, event_id: id}}} = socket) do
    %{integrations: integrations, timezone: timezone} = socket.assigns

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         :ok <- not_moving(socket, id),
         :ok <- EditGuard.writable(integrations, event),
         true <- EditGuard.movable?(integrations, event),
         {:ok, create} <- cast_params(socket, copy_params(event, integrations, timezone)),
         {:ok, socket} <- Creation.start(socket, copy_id(), create) do
      # The copy is drawn as a saving draft until its create answers.
      SurfaceData.push_events(socket, false)
    else
      refusal -> refuse_duplicate(socket, refusal)
    end
  end

  def duplicate(socket), do: socket

  defp refuse_duplicate(socket, {:error, :moving}),
    do: warn(socket, CalendarEditMessages.moving_message())

  defp refuse_duplicate(socket, {:error, :rate_limited, _message} = refusal),
    do: flash(socket, CalendarEditMessages.refusal(refusal))

  defp refuse_duplicate(socket, {:error, field, reason}) when is_atom(field),
    do: warn(socket, Creation.refusal_message(field, reason))

  defp refuse_duplicate(socket, {:error, _reason} = refusal),
    do: flash(socket, CalendarEditMessages.refusal(refusal))

  # Not an event the organiser can copy (a booking, or one missing now).
  defp refuse_duplicate(socket, _not_duplicable), do: socket

  @doc """
  Deletes the panel's event through the delete flow. The panel closes once
  the flow has taken the event over (a question on screen, or the delete
  scheduled); a refusal leaves the panel open beside its flash.
  """
  @spec delete(socket()) :: socket()
  def delete(%{assigns: %{panel: %{mode: :edit, event_id: id}}} = socket) do
    case not_moving(socket, id) do
      :ok ->
        started = Deletion.request(socket, id)
        if taken_over?(socket, started), do: PanelState.close(started), else: started

      {:error, :moving} ->
        warn(socket, CalendarEditMessages.moving_message())
    end
  end

  def delete(socket), do: socket

  defp taken_over?(before, started) do
    Enum.any?(
      [:series_prompt, :delete_prompt, :pending_deletes],
      &(before.assigns[&1] != started.assigns[&1])
    )
  end

  defp not_moving(socket, id),
    do: if(Transfer.moving?(socket, id), do: {:error, :moving}, else: :ok)

  # A copy's draft id, in the form `Creation` takes the hook's.
  defp copy_id, do: "dc" <> Integer.to_string(System.unique_integer([:positive]))

  # Once the create starts, the draft is the pending create's to draw
  # (`pending_creates`), so the panel stops drawing its own.
  defp create(%{assigns: %{panel: %{mode: :new, status: status} = panel}} = socket)
       when status != :saving do
    cond do
      Map.has_key?(socket.assigns.pending_creates, panel.draft_id) ->
        socket

      PanelGroupEvent.on?(group_allowed?(socket), panel.form) ->
        PanelGroupEvent.create(socket, panel)

      PanelMeeting.on?(panel.form) ->
        PanelMeeting.create(socket, panel)

      true ->
        start_create(socket, panel)
    end
  end

  defp create(socket), do: socket

  @doc "Whether the organiser's plan includes group bookings, which a group event is."
  @spec group_allowed?(socket()) :: boolean()
  def group_allowed?(socket), do: socket.assigns[:group_bookings_allowed] == true

  # Where a group event can take place, read once per draft and only for an
  # organiser who may make one.
  defp group_venues(socket) do
    if group_allowed?(socket),
      do: Venues.list_venues(socket.assigns.current_user.id),
      else: []
  end

  defp start_create(socket, panel) do
    with {:ok, create} <- cast_params(socket, panel.form),
         {:ok, socket} <- Creation.start(socket, panel.draft_id, create) do
      socket
      |> assign(:panel, %{panel | draft: nil, status: :saving})
      |> SurfaceData.push_events(false)
    else
      {:error, :rate_limited, _message} = refusal ->
        {_level, message} = CalendarEditMessages.refusal(refusal)
        assign(socket, :panel, %{panel | status: {:failed, message}})

      {:error, field, reason} ->
        assign(socket, :panel, %{
          panel
          | status: {:failed, Creation.refusal_message(field, reason)}
        })
    end
  end

  @doc """
  The New event form cast as a create (`CreateParams.cast/4`), an untitled
  draft named "New event" first. `PanelMeeting` casts a meeting's draft
  through it, so the two never disagree on the event's fields.
  """
  @spec cast_form(socket(), map()) :: {:ok, CreateParams.t()} | {:error, atom(), atom()}
  def cast_form(socket, form), do: cast_params(socket, form)

  # The draft the payload draws: the form as the domain casts it, or the
  # last accepted one with the reason in the header.
  defp cast(socket, form, previous) do
    case cast_params(socket, form) do
      {:ok, create} -> {create, :idle}
      {:error, field, reason} -> {previous, {:failed, Creation.refusal_message(field, reason)}}
    end
  end

  # The video select's "No video call" sends an empty value, which is no
  # video rather than a malformed id.
  defp cast_params(socket, form) do
    %{current_user: user, integrations: integrations, timezone: timezone} = socket.assigns

    # The form's "reminders" are a meeting's reminder emails (`PanelMeeting`),
    # not the event's own reminders, which this form never edits.
    params =
      form
      |> Map.delete("reminders")
      |> Map.put("title", untitled(form["title"]))
      |> Map.reject(fn {key, value} -> key == "video_integration_id" and value in [nil, ""] end)

    CreateParams.cast(user.id, integrations, params, timezone)
  end

  defp add_guest(%{assigns: %{panel: %{form: form} = panel}} = socket, raw) do
    user_id = socket.assigns.current_user.id
    guests = form["guests"]

    # The domain's own rules (valid address, not the organiser's, at most
    # `CreateParams.max_guests/0`), so the chips never promise an invitation
    # a create would drop.
    with {:ok, [email]} <- one_guest(user_id, raw),
         :ok <- not_yet_a_guest(guests, email),
         {:ok, _kept} <- CreateParams.guests(user_id, guests ++ [email]) do
      form = %{form | "guests" => guests ++ [email]}
      {draft, status} = cast(socket, form, panel.draft)

      socket
      |> assign(:panel, %{panel | form: form, draft: draft, status: status})
      |> assign(:guest_form_key, socket.assigns.guest_form_key + 1)
    else
      {:ok, []} ->
        warn(socket, Creation.guest_message(:organiser))

      {:error, :guests, :too_many} ->
        warn(socket, Creation.refusal_message(:guests, :too_many))

      {:error, :guests, _invalid} ->
        warn(socket, Creation.guest_message(:invalid))

      {:error, :already_a_guest, email} ->
        warn(socket, Creation.guest_message({:duplicate, email}))
    end
  end

  defp one_guest(user_id, raw), do: CreateParams.guests(user_id, [raw])

  defp not_yet_a_guest(guests, email),
    do: if(email in guests, do: {:error, :already_a_guest, email}, else: :ok)

  # The guests the hook sent, checked as a create checks them; ones the
  # domain refuses leave the form with none and the reason in the header.
  defp typed_guests(socket, list) when is_list(list) do
    case CreateParams.guests(socket.assigns.current_user.id, Enum.filter(list, &is_binary/1)) do
      {:ok, guests} ->
        {guests, :idle}

      {:error, field, reason} ->
        {[], {:failed, Creation.refusal_message(field, reason)}}
    end
  end

  defp typed_guests(_socket, _other), do: {[], :idle}

  # The form's fields; in the all-day state the end it shows is the last day,
  # inclusive, and the form keeps the exclusive end the create params use.
  defp form_fields(params, form) do
    all_day =
      if Map.has_key?(params, "all_day"), do: truthy?(params["all_day"]), else: form["all_day"]

    params
    |> Map.take(@text_fields)
    |> Map.new(fn {key, value} -> {key, text(value)} end)
    |> Map.merge(
      Map.take(%{"all_day" => all_day, "free" => truthy?(params["free"])}, present_keys(params))
    )
    |> exclusive_end(all_day, form["all_day"])
  end

  defp present_keys(params), do: Enum.filter(["all_day", "free"], &Map.has_key?(params, &1))

  defp exclusive_end(%{"end" => last} = fields, true, true) when is_binary(last) do
    case Date.from_iso8601(last) do
      {:ok, date} -> %{fields | "end" => date |> Date.add(1) |> Date.to_iso8601()}
      _invalid -> fields
    end
  end

  defp exclusive_end(fields, _all_day, _was_all_day), do: fields

  # Turning all day on keeps the start's day as a one-day event; turning it
  # off gives that day 09:00 to 10:00.
  defp convert_all_day(%{"all_day" => same} = form, %{"all_day" => same}), do: form

  defp convert_all_day(%{"all_day" => true, "start" => start} = form, _was) do
    day = String.slice(start || "", 0, 10)

    case Date.from_iso8601(day) do
      {:ok, date} -> %{form | "start" => day, "end" => date |> Date.add(1) |> Date.to_iso8601()}
      _invalid -> form
    end
  end

  defp convert_all_day(%{"all_day" => false, "start" => start} = form, _was) do
    day = String.slice(start || "", 0, 10)
    %{form | "start" => day <> "T09:00", "end" => day <> "T10:00"}
  end

  # A changed start moves the end with it, keeping the length.
  defp follow_start(form, old, ["start"]) do
    with true <- form["all_day"] == old["all_day"],
         {:ok, old_start} <- wall(old["start"], old["all_day"]),
         {:ok, old_end} <- wall(old["end"], old["all_day"]),
         {:ok, new_start} <- wall(form["start"], form["all_day"]) do
      length = NaiveDateTime.diff(old_end, old_start)
      %{form | "end" => format_wall(NaiveDateTime.add(new_start, length), form["all_day"])}
    else
      _unreadable -> form
    end
  end

  defp follow_start(form, _old, _target), do: form

  # A timed draft's date and time picker posts the date alone while its time
  # is missing; that is unreadable here, not midnight.
  defp wall(text, all_day) when is_binary(text) do
    case {String.length(text), all_day == true} do
      {10, true} ->
        with {:ok, date} <- Date.from_iso8601(text), do: NaiveDateTime.new(date, ~T[00:00:00])

      {16, false} ->
        NaiveDateTime.from_iso8601(text <> ":00")

      _other ->
        :error
    end
  end

  defp wall(_text, _all_day), do: :error

  defp format_wall(naive, true), do: naive |> NaiveDateTime.to_date() |> Date.to_iso8601()
  defp format_wall(naive, _timed), do: naive |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  defp copy_params(event, integrations, timezone) do
    timing =
      if event.all_day,
        do: %{
          "start" => event.start_date |> Date.add(1) |> Date.to_iso8601(),
          "end" => event |> EventPayload.exclusive_end() |> Date.add(1) |> Date.to_iso8601()
        },
        else: %{
          "start" => next_day_wall(event.start_at, timezone),
          "end" => next_day_wall(event.end_at, timezone)
        }

    Map.merge(timing, %{
      "title" => Map.get(event, :summary) || "",
      "all_day" => event.all_day,
      "calendar" => Transfer.calendar_key(event, integrations),
      "location" => Map.get(event, :location) || "",
      "description" => EventVideo.without_join_lines(Map.get(event, :description)) || "",
      "free" => Map.get(event, :transparency) == "transparent",
      "guests" => []
    })
  end

  defp next_day_wall(at, timezone),
    do:
      at
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_naive()
      |> NaiveDateTime.add(1, :day)
      |> format_wall(false)

  defp untitled(title) do
    case String.trim(title || "") do
      "" -> dgettext("dashboard_calendar_editing", "New event")
      trimmed -> trimmed
    end
  end

  defp text(value) when is_binary(value), do: String.replace(value, "\x00", "")
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "on"]

  defp warn(socket, message), do: flash(socket, {:warning, message})

  defp flash(socket, message) do
    send(self(), {:flash, message})
    socket
  end
end
