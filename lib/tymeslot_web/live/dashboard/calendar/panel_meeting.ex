defmodule TymeslotWeb.Dashboard.Calendar.PanelMeeting do
  @moduledoc """
  "Send as a Tymeslot meeting" in the side panel's New event state: the
  draft becomes an ad hoc booking (`Bookings.CreateAdHoc`) instead of a
  bare calendar event. The first guest is the one the meeting is with and
  gives it their name; the others are invited as its guests; every email
  about it is written in the language chosen here; the notes go to the
  guests as a note; and the reminder emails ticked are the only ones sent
  (see `Tymeslot.CalendarGrid.MeetingParams`).

  The meeting's fields live in the panel's `form` beside the event's own
  (`"meeting"`, `"guest_name"`, `"locale"`, `"reminders"`), so the form
  draws what was typed. The box counts only while the draft has a guest
  (`on?/1`). A meeting has times: ticking it makes an all-day draft timed.

  Create hands the booking to the dashboard
  (`{:execute_create_ad_hoc_meeting, params}`, answered by
  `TymeslotWeb.Dashboard.CalendarEventHandlers`), which flashes the outcome
  and tells the surface: `created/1` closes the panel, `failed/1` offers
  Create again beside the flash that says why. The draft stays the panel's
  while the meeting saves, so a panel closed meanwhile takes it off the grid
  (`PanelState`); the reload after the booking shows the meeting if it was
  made.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Locales
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelState

  @type socket :: Phoenix.LiveView.Socket.t()

  @fields ~w(meeting guest_name locale reminders)

  @doc "The meeting fields a new draft starts with, for the organiser `user`."
  @spec defaults(map()) :: map()
  def defaults(user),
    do: %{
      "meeting" => false,
      "guest_name" => "",
      "locale" => Locales.guest_default_locale(user),
      "reminders" => []
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

  defp field({"meeting", value}), do: {"meeting", value in [true, "true", "on"]}

  defp field({"reminders", keys}) when is_list(keys),
    do: {"reminders", Enum.filter(keys, &(&1 in MeetingParams.reminder_choices()))}

  defp field({"reminders", _other}), do: {"reminders", []}
  defp field({key, value}) when is_binary(value), do: {key, String.replace(value, "\x00", "")}
  defp field({key, _value}), do: {key, ""}

  defp timed(%{"meeting" => true} = fields), do: Map.put(fields, "all_day", false)
  defp timed(fields), do: fields

  @doc "Whether the form describes a meeting: the box ticked, and a guest to meet."
  @spec on?(map()) :: boolean()
  def on?(%{"meeting" => true, "guests" => [_first | _rest]}), do: true
  def on?(_form), do: false

  @doc """
  Creates the panel's meeting: checks it, spends the budget, and hands it to
  the dashboard. A refusal stays in the panel's header.
  """
  @spec create(socket(), map()) :: socket()
  def create(socket, panel) do
    user = socket.assigns.current_user
    form = titled(panel.form)

    with {:ok, create} <- PanelNew.cast_form(socket, form),
         {:ok, params} <- MeetingParams.build(create, form, user.id),
         :ok <- MeetingParams.rate_limit(user.id) do
      send(self(), {:execute_create_ad_hoc_meeting, params})
      assign(socket, :panel, %{panel | status: :saving})
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

  @doc "The meeting was booked: the panel that asked for it closes."
  @spec created(socket()) :: socket()
  def created(%{assigns: %{panel: %{mode: :new, status: :saving} = panel}} = socket),
    do: if(on?(panel.form), do: PanelState.close(socket), else: socket)

  def created(socket), do: socket

  @doc "The booking refused the meeting: Create is offered again (the flash says why)."
  @spec failed(socket()) :: socket()
  def failed(%{assigns: %{panel: %{mode: :new, status: :saving} = panel}} = socket),
    do: if(on?(panel.form), do: assign(socket, :panel, %{panel | status: :idle}), else: socket)

  def failed(socket), do: socket

  @doc "What a refusal from `MeetingParams.build/3` or `CreateParams.cast/4` says."
  @spec refusal_message(atom(), atom()) :: String.t()
  def refusal_message(:guest_name, :blank),
    do: dgettext("dashboard_calendar_events", "Guest name is required")

  def refusal_message(:guests, :too_many),
    do:
      dgettext("dashboard_calendar_editing", "You can invite at most %{count} guests at once.",
        count: MeetingParams.max_guests()
      )

  # Notes allow more than a meeting's note does, so text typed before the box
  # was ticked can be too long.
  def refusal_message(:note, :too_long),
    do:
      dgettext(
        "dashboard_calendar_power",
        "The note to the guest is too long. Keep it to 2,000 characters or fewer."
      )

  # The form offers no way to send the rest; they come from forged input.
  def refusal_message(field, reason)
      when field in [:guests, :guest_name, :note, :locale, :all_day],
      do: Creation.refusal_message(:params, reason)

  def refusal_message(field, reason), do: Creation.refusal_message(field, reason)

  # An untitled meeting is named after its guest, which is what the
  # organiser will recognise it by.
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
