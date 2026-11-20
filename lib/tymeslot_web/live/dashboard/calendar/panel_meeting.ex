defmodule TymeslotWeb.Dashboard.Calendar.PanelMeeting do
  @moduledoc """
  "Send as a Tymeslot meeting" in the side panel's New event state: the
  draft becomes an ad hoc booking (`Bookings.CreateAdHoc`) instead of a
  bare calendar event. The first guest is the one the meeting is with and
  gives it their name; the others are invited as its guests; every email
  about it is written in the language chosen here; the notes go to the
  guests as a note; and the reminder emails chosen are the only ones sent
  (see `Tymeslot.CalendarGrid.MeetingParams`).

  The meeting's fields live in the panel's `form` beside the event's own
  (`"meeting"`, `"main_participant"`, `"guest_name"`, `"locale"`,
  `"location_choice"`, `"location_custom"`), so the form draws what was
  typed; its reminders are the panel's reminder picker
  (`PanelMeetingReminders`). With "Main participant" off the host manages
  the meeting alone: every guest is an equal guest, no guest name is asked
  for, and the meeting is known by its title, which it then needs. Its
  place is none, a saved location, or one typed in; a Place typed before the
  box was ticked becomes the one typed in (`carry_place/2`). The box counts only
  while the draft has a guest (`on?/1`). A meeting has times: ticking it
  makes an all-day draft timed.

  Create hands the booking to the dashboard
  (`{:execute_create_ad_hoc_meeting, request, params}`, answered by
  `TymeslotWeb.Dashboard.CalendarEventHandlers`), which flashes the outcome
  and tells the surface: `created/2` closes the panel, `failed/2` offers
  Create again beside the flash that says why. `request` is a ref the panel
  keeps while it saves (`meeting_request`), so only the panel that asked
  hears the answer: a meeting whose panel was closed meanwhile still flashes
  its outcome, but neither closes nor re-enables a newer draft's panel. The
  draft stays the panel's while the meeting saves, so a panel closed
  meanwhile takes it off the grid (`PanelState`); the reload after the
  booking shows the meeting if it was made.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Guests
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelMeetingReminders
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelState

  @type socket :: Phoenix.LiveView.Socket.t()

  @fields ~w(meeting main_participant guest_name locale location_choice location_custom)

  @doc "The meeting fields a new draft starts with, for the organiser `user`."
  @spec defaults(map()) :: map()
  def defaults(user),
    do: %{
      "meeting" => false,
      "main_participant" => true,
      "guest_name" => "",
      "location_choice" => "",
      "location_custom" => "",
      "locale" => Locales.guest_default_locale(user)
    }

  @doc """
  The meeting fields among a form change's `params`, cleaned; with the box
  ticked, all day is off.
  """
  @spec fields(map()) :: map()
  def fields(params) do
    params
    |> Map.take(@fields)
    |> Map.new(&field/1)
    |> timed()
  end

  defp field({key, value}) when key in ["meeting", "main_participant"],
    do: {key, value in [true, "true", "on"]}

  defp field({key, value}) when is_binary(value), do: {key, String.replace(value, "\x00", "")}
  defp field({key, _value}), do: {key, ""}

  defp timed(%{"meeting" => true} = fields), do: Map.put(fields, "all_day", false)
  defp timed(fields), do: fields

  @doc """
  A Place typed while the draft was a plain event (in the panel, or in
  quick create) carries into the meeting's location as a custom one when
  the box is ticked, and a saved location chosen for it as that saved
  location, rather than being dropped: a meeting takes its place
  from its own fields. Only on the change that ticks it, and only while no
  meeting location has been chosen, so a choice is never overwritten.
  """
  @spec carry_place(map(), map()) :: map()
  def carry_place(
        %{"meeting" => true, "location_choice" => "", "location_venue" => venue} = form,
        %{"meeting" => false}
      )
      when is_binary(venue) and venue != "",
      do: %{form | "location_choice" => "venue:" <> venue}

  def carry_place(
        %{"meeting" => true, "location_choice" => "", "location" => place} = form,
        %{"meeting" => false}
      )
      when is_binary(place) do
    case String.trim(place) do
      "" -> form
      typed -> Map.merge(form, %{"location_choice" => "custom", "location_custom" => typed})
    end
  end

  def carry_place(form, _was), do: form

  @doc """
  Whether the form describes a meeting: the box ticked, and a guest to meet
  (`guests?/1`).
  """
  @spec on?(map()) :: boolean()
  def on?(%{"meeting" => true} = form), do: guests?(form)
  def on?(_form), do: false

  @doc """
  Whether the draft has a guest: one added, or one typed into the guest
  field and not added yet, which Create adds first
  (`PanelNewGuests.take_pending/3`).
  """
  @spec guests?(map()) :: boolean()
  def guests?(form), do: form["guests"] not in [nil, []] or (form["guest_pending"] || "") != ""

  @doc """
  Creates the panel's meeting: checks it, spends the budget, and hands it to
  the dashboard. A refusal stays in the panel's header; a lead time typed
  into the reminder picker that cannot be added stays in the picker.
  """
  @spec create(socket(), map()) :: socket()
  def create(socket, panel) do
    case PanelMeetingReminders.commit_pending(panel) do
      {:ok, picker} -> book(socket, Map.put(panel, :reminder_picker, picker))
      {:error, picker} -> assign(socket, :panel, Map.put(panel, :reminder_picker, picker))
    end
  end

  defp book(socket, panel) do
    user = socket.assigns.current_user
    form = panel.form |> titled() |> Map.put("reminders", panel.reminder_picker.reminders)

    with {:ok, create} <- PanelNew.cast_form(socket, form, :optional),
         {:ok, params} <- MeetingParams.build(create, form, user.id),
         :ok <- MeetingParams.rate_limit(user.id) do
      request = make_ref()
      send(self(), {:execute_create_ad_hoc_meeting, request, params})
      assign(socket, :panel, Map.merge(panel, %{status: :saving, meeting_request: request}))
    else
      {:error, :rate_limited, _message} ->
        refuse(
          socket,
          panel,
          dgettext("dashboard_calendar_events", "Too many new meetings. Please wait a moment.")
        )

      {:error, field, reason} ->
        refuse(socket, panel, refusal_message(field, reason))
    end
  end

  @doc """
  The meeting `request` was booked: the panel that asked for it closes. Any
  other panel, such as a newer draft saving its own meeting, stays as it is.
  """
  @spec created(socket(), reference()) :: socket()
  def created(
        %{assigns: %{panel: %{mode: :new, status: :saving, meeting_request: request} = panel}} =
          socket,
        request
      ),
      do: if(on?(panel.form), do: PanelState.close(socket), else: socket)

  def created(socket, _request), do: socket

  @doc """
  The booking refused the meeting `request`: the panel that asked for it
  offers Create again (the flash says why).
  """
  @spec failed(socket(), reference()) :: socket()
  def failed(
        %{assigns: %{panel: %{mode: :new, status: :saving, meeting_request: request} = panel}} =
          socket,
        request
      ),
      do: if(on?(panel.form), do: assign(socket, :panel, %{panel | status: :idle}), else: socket)

  def failed(socket, _request), do: socket

  @doc "What a refusal from `MeetingParams.build/3` or `CreateParams.cast/4` says."
  @spec refusal_message(atom(), atom()) :: String.t()
  def refusal_message(:guest_name, :blank),
    do: dgettext("dashboard_calendar_events", "Guest name is required")

  def refusal_message(:guests, :too_many),
    do:
      dgettext("dashboard_calendar_editing", "You can invite at most %{count} guests at once.",
        count: MeetingParams.max_guests()
      )

  # Without a main participant every guest counts against the guests'
  # own limit.
  def refusal_message(:guests, :too_many_guests),
    do:
      dgettext("dashboard_calendar_editing", "You can invite at most %{count} guests at once.",
        count: Guests.max_guests()
      )

  def refusal_message(:title, :blank),
    do:
      dgettext(
        "dashboard_calendar_events",
        "Add a title. A meeting without a main participant is known by its title."
      )

  def refusal_message(:location, :invalid),
    do:
      dgettext(
        "dashboard_calendar_events",
        "That location can no longer be used. Please choose another one."
      )

  def refusal_message(:location, :unsafe), do: Creation.refusal_message(:location, :invalid)

  # A Place typed for the event carries into the meeting
  # (`carry_place/2`), and an event's may run past a meeting's limit
  # (`CreateAdHoc.custom_location_max_length/0`).
  def refusal_message(:location, :too_long),
    do:
      dgettext(
        "dashboard_calendar_events",
        "The place is too long for a meeting. Keep it under 500 characters."
      )

  # Notes allow more than a meeting's note does, so text typed before the box
  # was ticked can be too long.
  def refusal_message(:note, :too_long),
    do:
      dgettext(
        "dashboard_calendar_power",
        "The note to the guest is too long. Keep it to 2,000 characters or fewer."
      )

  # The form offers no way to send the rest (a location choice that is
  # neither a saved location nor a place typed in, say); they come from
  # forged input.
  def refusal_message(field, reason)
      when field in [:guests, :guest_name, :note, :locale, :all_day, :location],
      do: Creation.refusal_message(:params, reason)

  def refusal_message(field, reason), do: Creation.refusal_message(field, reason)

  # An untitled meeting is named after its guest, which is what the
  # organiser will recognise it by. Without a main participant there is
  # no such guest, and the meeting needs a title of its own.
  defp titled(%{"main_participant" => false} = form), do: form

  defp titled(form) do
    name = String.trim(form["guest_name"] || "")

    if String.trim(form["title"] || "") == "" and name != "",
      do:
        Map.put(
          form,
          "title",
          dgettext("dashboard_calendar_events", "Meeting with %{name}", name: name)
        ),
      else: form
  end

  defp refuse(socket, panel, message),
    do: assign(socket, :panel, %{panel | status: {:failed, message}})
end
