defmodule Tymeslot.MeetingTypes.ReminderValidation do
  @moduledoc """
  Validation and normalisation for meeting type reminder configuration.

  Handles parsing, normalisation, and policy enforcement for reminder
  settings attached to meeting types.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset, only: [add_error: 3, add_error: 4, get_change: 2]

  alias Tymeslot.MeetingTypes.Reminders

  @max_reminders 3
  @max_reminder_seconds 365 * 24 * 60 * 60

  @doc """
  Validates a reminder configuration value from form input.

  Accepts `nil`, an empty string, a JSON string, a map, or a list of
  reminder maps. Returns `{:ok, normalised_reminders}` on success or
  `{:error, %{reminder_config: message}}` on failure.
  """
  @spec validate_reminder_config(any(), map()) :: {:ok, list()} | {:error, map()}
  def validate_reminder_config(nil, _metadata), do: {:ok, []}
  def validate_reminder_config("", _metadata), do: {:ok, []}

  def validate_reminder_config(reminder_config, _metadata) do
    with {:ok, reminders} <- parse_and_normalize_reminders(reminder_config),
         :ok <- validate_reminders_policy(reminders) do
      {:ok, reminders}
    else
      {:error, message} -> {:error, %{reminder_config: message}}
    end
  end

  @doc """
  Parses and normalises reminder input into a list of reminder maps.

  Accepts a JSON string, a map (keyed by index), or a list of reminder
  maps. Each reminder is normalised via `Reminders.normalize_reminder_string_keys/1`.
  """
  @spec parse_and_normalize_reminders(any()) :: {:ok, list()} | {:error, String.t()}
  def parse_and_normalize_reminders(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> parse_and_normalize_reminders(decoded)
      _invalid -> {:error, "Invalid reminder settings format"}
    end
  end

  def parse_and_normalize_reminders(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> parse_and_normalize_reminders()
  end

  def parse_and_normalize_reminders(reminders) when is_list(reminders) do
    results = Enum.map(reminders, &Reminders.normalize_reminder_string_keys/1)

    if Enum.any?(results, &match?({:error, _reason}, &1)) do
      {:error, "Reminder settings must include valid values and units"}
    else
      {:ok, Enum.map(results, fn {:ok, reminder} -> reminder end)}
    end
  end

  def parse_and_normalize_reminders(_other), do: {:error, "Invalid reminder settings format"}

  @doc """
  The maximum number of reminders one meeting type may carry.
  """
  @spec max_reminders() :: pos_integer()
  def max_reminders, do: @max_reminders

  @doc """
  Checks a normalised reminder list against the reminder policy: at most
  `max_reminders/0` reminders, no two for the same interval, and none more
  than a year ahead.

  `already_held` is the normalised list the meeting type had before this
  change. The year limit is newer than some stored reminders, so it judges
  only what the change adds: a reminder the meeting type already held stays
  acceptable, or an unrelated edit to that meeting type could never be saved.

  Returns the first rule broken as an atom, so each caller can word it for
  its own surface.
  """
  @spec check_policy([map()], [map()]) :: :ok | {:error, :too_many | :duplicate | :exceeds_max}
  def check_policy(reminders, already_held \\ [])
      when is_list(reminders) and is_list(already_held) do
    cond do
      length(reminders) > @max_reminders -> {:error, :too_many}
      Reminders.duplicate_reminders?(reminders) -> {:error, :duplicate}
      Enum.any?(reminders -- already_held, &reminder_exceeds_max?/1) -> {:error, :exceeds_max}
      true -> :ok
    end
  end

  @doc """
  Enforces reminder policy constraints: maximum count, uniqueness, and
  maximum interval. See `check_policy/1`.
  """
  @spec validate_reminders_policy(list()) :: :ok | {:error, String.t()}
  def validate_reminders_policy(reminders) do
    case check_policy(reminders) do
      :ok ->
        :ok

      {:error, :too_many} ->
        {:error, "You can configure up to #{@max_reminders} reminders"}

      {:error, :duplicate} ->
        {:error, "Reminder settings must be unique"}

      {:error, :exceeds_max} ->
        {:error, "Reminders cannot be set for more than 1 year in advance"}
    end
  end

  @doc """
  Returns `true` if a single reminder exceeds the maximum allowed interval
  (1 year).
  """
  @spec reminder_exceeds_max?(map()) :: boolean()
  def reminder_exceeds_max?(%{value: v, unit: u}) do
    seconds = Reminders.reminder_interval_seconds(v, u)
    seconds > @max_reminder_seconds
  end

  @doc """
  Validates the `reminder_config` change on a meeting type changeset: a list,
  at most `max_reminders/0` entries, each well-formed, no duplicates and none
  further ahead than a year.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    case get_change(changeset, :reminder_config) do
      nil ->
        changeset

      reminders when is_list(reminders) ->
        validate_reminder_list(changeset, reminders)

      _other ->
        add_error(
          changeset,
          :reminder_config,
          dgettext_noop("errors", "must be a list of reminder settings")
        )
    end
  end

  # The count is checked before the entries, so an oversized list reports that
  # rather than whichever of its entries happens to be malformed.
  defp validate_reminder_list(changeset, reminders) do
    normalized = Enum.map(reminders, &Reminders.normalize_reminder/1)

    result =
      cond do
        length(reminders) > max_reminders() ->
          {:error, :too_many}

        Enum.any?(normalized, &match?({:error, _reason}, &1)) ->
          {:error, :invalid}

        true ->
          normalized
          |> Enum.map(fn {:ok, reminder} -> reminder end)
          |> check_policy(Reminders.normalize_reminders(changeset.data.reminder_config))
      end

    case result do
      :ok -> changeset
      {:error, reason} -> add_reminder_error(changeset, reason)
    end
  end

  defp add_reminder_error(changeset, :too_many),
    do:
      add_error(changeset, :reminder_config, "cannot have more than %{count} reminders",
        count: max_reminders()
      )

  defp add_reminder_error(changeset, :invalid),
    do:
      add_error(
        changeset,
        :reminder_config,
        dgettext_noop("errors", "contains invalid reminder settings")
      )

  defp add_reminder_error(changeset, :duplicate),
    do:
      add_error(
        changeset,
        :reminder_config,
        dgettext_noop("errors", "contains duplicate reminders")
      )

  defp add_reminder_error(changeset, :exceeds_max),
    do:
      add_error(
        changeset,
        :reminder_config,
        dgettext_noop("errors", "cannot be set for more than 1 year in advance")
      )
end
