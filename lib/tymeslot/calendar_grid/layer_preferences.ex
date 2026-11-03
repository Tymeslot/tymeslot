defmodule Tymeslot.CalendarGrid.LayerPreferences do
  @moduledoc """
  The calendar's bookable-times layer as the organiser left it: whether
  it shows, and which meeting type's bookable times it draws.

  Both live on the organiser's calendar preferences (`bookable_layer`,
  `bookable_meeting_type_id`). The layer shows one meeting type at a time:
  the one chosen, while it is still active and not archived, else the first
  such type in the organiser's own order. With none there is nothing to draw.

  A fixed-date type (`Tymeslot.MeetingTypes.FixedDates`, a one-off event
  among them) is never one of them: its planned sessions are joined, never
  started, so it has no bookable times to draw.
  """

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.FixedDates

  @typedoc """
  A meeting type the layer can show, as the rail lists it; `duration` is in
  minutes (quick create's "Open for booking" kind sizes its slot by it).
  """
  @type choice :: %{id: pos_integer(), name: String.t(), duration: pos_integer()}

  @doc """
  The organiser's active, unarchived meeting types without planned sessions, in
  their own order.
  """
  @spec meeting_types(pos_integer()) :: [choice()]
  def meeting_types(user_id) do
    for type <- MeetingTypes.get_bookable_meeting_types(user_id),
        not FixedDates.sessions?(type),
        do: %{id: type.id, name: type.name, duration: type.duration_minutes}
  end

  @doc """
  The meeting type the layer shows: the chosen one when it is among
  `choices`, else the first of them; `nil` when there are none.
  """
  @spec meeting_type(CalendarPreferencesSchema.t() | map(), [choice()]) :: choice() | nil
  def meeting_type(%{bookable_meeting_type_id: id}, choices),
    do: Enum.find(choices, List.first(choices), &(&1.id == id))

  @doc "Shows (`true`) or hides the layer for the organiser."
  @spec set_layer(pos_integer(), boolean()) ::
          {:ok, CalendarPreferencesSchema.t()} | {:error, Ecto.Changeset.t()}
  def set_layer(user_id, on?) when is_boolean(on?),
    do: CalendarPreferencesQueries.upsert(user_id, %{bookable_layer: on?})

  @doc """
  Makes `id` (an integer or its decimal string) the meeting type the layer
  shows. Only one of `meeting_types/1` can be chosen; anything else, another organiser's type included, is
  `{:error, :not_found}`.
  """
  @spec choose_meeting_type(pos_integer(), term()) ::
          {:ok, choice()} | {:error, :not_found | Ecto.Changeset.t()}
  def choose_meeting_type(user_id, id) do
    with {:ok, id} <- parse_id(id),
         {:ok, choice} <- find_choice(meeting_types(user_id), id),
         {:ok, _preferences} <-
           CalendarPreferencesQueries.upsert(user_id, %{bookable_meeting_type_id: id}) do
      {:ok, choice}
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _other -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  defp find_choice(choices, id) do
    case Enum.find(choices, &(&1.id == id)) do
      nil -> {:error, :not_found}
      choice -> {:ok, choice}
    end
  end
end
