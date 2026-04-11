defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Init do
  @moduledoc "Initialisation and form data building for MeetingTypeForm."

  alias Phoenix.Component
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  Initialises the socket from the assigned meeting type on first render.

  A no-op when the socket is already initialised (guarded by `:__initialized__`).
  """
  @spec maybe_initialize(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_initialize(%{assigns: %{__initialized__: true}} = socket), do: socket

  def maybe_initialize(%{assigns: assigns} = socket) do
    type = Map.get(assigns, :type)

    socket
    |> Component.assign(:selected_icon, get_selected_icon(type))
    |> Component.assign(:meeting_mode, get_meeting_mode(type))
    |> Component.assign(:selected_video_integration_id, get_video_integration_id(type))
    |> Component.assign(
      :selected_calendar_integration_id,
      get_calendar_integration_id(type)
    )
    |> Component.assign(:selected_target_calendar_id, get_target_calendar_id(type))
    |> Component.assign(:reminders, get_reminders(type))
    |> then(fn socket ->
      if id = socket.assigns.selected_calendar_integration_id do
        Component.assign(
          socket,
          :available_calendars,
          fetch_available_calendars(id, socket.assigns.calendar_integrations)
        )
      else
        socket
      end
    end)
    |> Component.assign(:form_data, build_form_data(type))
    |> Component.assign(:__initialized__, true)
  end

  @doc "Builds the initial form data map from an existing meeting type or nil."
  @spec build_form_data(Ecto.Schema.t() | nil) :: map()
  def build_form_data(nil) do
    %{"name" => "", "duration" => "30", "description" => "", "icon" => "none"}
  end

  def build_form_data(type) do
    %{
      "name" => type.name || "",
      "duration" => to_string(type.duration_minutes || 30),
      "description" => type.description || "",
      "icon" => type.icon || "none"
    }
  end

  @doc "Returns the selected icon for a meeting type, or `\"none\"` when absent."
  @spec get_selected_icon(Ecto.Schema.t() | nil) :: String.t()
  def get_selected_icon(nil), do: "none"
  def get_selected_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  def get_selected_icon(_arg), do: "none"

  @doc "Returns the meeting mode string for a meeting type."
  @spec get_meeting_mode(Ecto.Schema.t() | nil) :: String.t()
  def get_meeting_mode(%{allow_video: true}), do: "video"
  def get_meeting_mode(_arg), do: "personal"

  @doc "Returns the video integration id as an integer, or nil."
  @spec get_video_integration_id(Ecto.Schema.t() | nil) :: integer() | nil
  def get_video_integration_id(nil), do: nil
  def get_video_integration_id(%{video_integration_id: nil}), do: nil
  def get_video_integration_id(%{video_integration_id: id}) when is_integer(id), do: id

  def get_video_integration_id(%{video_integration_id: id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, _value} -> int
      :error -> nil
    end
  end

  def get_video_integration_id(_arg), do: nil

  @doc "Returns the calendar integration id for a meeting type, or nil."
  @spec get_calendar_integration_id(Ecto.Schema.t() | nil) :: integer() | nil
  def get_calendar_integration_id(nil), do: nil
  def get_calendar_integration_id(%{calendar_integration_id: nil}), do: nil
  def get_calendar_integration_id(%{calendar_integration_id: id}), do: id

  @doc "Returns the target calendar id for a meeting type, or nil."
  @spec get_target_calendar_id(Ecto.Schema.t() | nil) :: String.t() | nil
  def get_target_calendar_id(nil), do: nil
  def get_target_calendar_id(%{target_calendar_id: nil}), do: nil
  def get_target_calendar_id(%{target_calendar_id: id}), do: id

  @doc "Fetches the available calendar list for a given integration id."
  @spec fetch_available_calendars(integer(), list()) :: list()
  def fetch_available_calendars(integration_id, integrations) do
    integration = Enum.find(integrations, &(&1.id == integration_id))

    if integration && integration.calendar_list do
      integration.calendar_list
    else
      []
    end
  end

  @doc "Returns the normalised reminders list for a meeting type."
  @spec get_reminders(Ecto.Schema.t() | nil) :: list()
  def get_reminders(nil), do: [%{value: 30, unit: "minutes"}]

  def get_reminders(%{reminder_config: reminders}) when is_list(reminders) do
    Enum.flat_map(reminders, fn r ->
      case ReminderUtils.normalize_reminder(r) do
        {:ok, reminder} -> [reminder]
        _other -> []
      end
    end)
  end

  def get_reminders(_arg), do: [%{value: 30, unit: "minutes"}]
end
