defmodule TymeslotWeb.Dashboard.Polls.PollFormAttrs do
  @moduledoc """
  The create form's submitted params turned into the attrs `Tymeslot.Polls`
  saves a poll or draft from: local times to UTC in the form's timezone, the
  rows in the order the form issued them, and the invitee text parsed.

  The inverse of `DraftFields`, which turns a saved draft back into the
  form's assigns. Takes `PollForm`'s assigns for the values the params may
  not carry: the timezone, duration, the vote-notification default, the
  reminder picker and the access choice.
  """

  alias Tymeslot.Polls.Invitations

  alias TymeslotWeb.Dashboard.Polls.{
    LocalTime,
    PollAccess,
    PollDuration,
    PollLocationField,
    PollReminders
  }

  @doc "The attrs for `params`, the invitees aside (see `invitees/1`)."
  @spec attrs(map(), map()) :: map()
  def attrs(params, assigns) do
    timezone = Map.get(params, "timezone", assigns.timezone)

    params
    |> PollLocationField.attrs()
    |> Map.merge(%{
      title: Map.get(params, "title", ""),
      description: blank_to_nil(Map.get(params, "description")),
      timezone: timezone,
      duration_minutes: PollDuration.parse(Map.get(params, "duration", assigns.duration)),
      meeting_type_id: parse_meeting_type_id(Map.get(params, "meeting_type_id")),
      deadline_at: LocalTime.to_utc(Map.get(params, "deadline"), timezone),
      notify_on_vote: checked?(params, "notify_on_vote", assigns.notify_on_vote),
      reminder_config: PollReminders.to_config(assigns.reminder_picker),
      invite_only:
        params |> PollAccess.resolve(nil, assigns) |> elem(0) |> PollAccess.invite_only?(),
      slots: build_slots(Map.get(params, "slots", %{}), timezone)
    })
  end

  @doc "The invitees typed into `params`, tagged `:invitees` when they do not parse."
  @spec invitees(map()) :: {:ok, list()} | {:error, {:invitees, term()}}
  def invitees(params) do
    case Invitations.parse(Map.get(params, "invitees")) do
      {:ok, invitees} -> {:ok, invitees}
      {:error, reason} -> {:error, {:invitees, reason}}
    end
  end

  @doc "Whether any invitee is typed. Reminders reach only invitees, so the picker waits until someone is."
  @spec invitees_entered?(String.t() | nil) :: boolean()
  def invitees_entered?(invitees), do: String.trim(invitees || "") != ""

  @doc "A checkbox's value in `params`, or `default` when the params do not carry it."
  @spec checked?(map(), String.t(), boolean()) :: boolean()
  def checked?(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value -> value == "true"
    end
  end

  defp build_slots(values, timezone) do
    values
    |> Enum.sort_by(fn {key, _value} -> slot_order(key) end)
    |> Enum.map(fn {_key, value} -> LocalTime.to_utc(value, timezone) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn start_time -> %{start_time: start_time} end)
  end

  # Rows are keyed by the counter the form issued; a forged key sorts last.
  defp slot_order(key) do
    case Integer.parse(key) do
      {order, ""} -> order
      _forged -> :infinity
    end
  end

  defp parse_meeting_type_id(id) when id in [nil, ""], do: nil

  defp parse_meeting_type_id(id) do
    case Integer.parse(id) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
