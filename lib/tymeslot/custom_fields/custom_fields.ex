defmodule Tymeslot.CustomFields do
  @moduledoc """
  Public API for custom booking fields.

  Hosts attach custom-field definitions to a meeting type; bookers
  answer them during the booking flow. Definitions are snapshotted onto
  each booking at submission time so past bookings stay pinned to the
  questions they were actually asked.
  """

  alias Tymeslot.CustomFields.{Snapshot, Validator}

  # Hard ceiling on a raw binary answer before any type-specific validation
  # runs. Type validators apply tighter, type-appropriate caps; this is a
  # defensive backstop so a single crafted field can't bloat the persisted
  # JSONB regardless of type.
  @max_raw_answer_length 5_000

  @doc """
  Builds a frozen snapshot of a meeting type's custom-field definitions.

  Intentionally ungated by plan. The booker flow keeps collecting answers
  even if the host has since downgraded — this is a deliberate
  data-retention choice so existing booking links don't silently start
  dropping questions. The plan gate is enforced at *write* time, when a
  host attaches custom fields to a meeting type
  (`Tymeslot.MeetingTypes.gate_custom_fields_change/2`), not at booking time.
  """
  @spec snapshot_for(map()) :: [map()]
  defdelegate snapshot_for(meeting_type), to: Snapshot, as: :from_meeting_type

  @doc "Validates a single answer for a definition (or snapshot row)."
  @spec validate_answer(any(), map()) :: {:ok, term()} | {:error, String.t()}
  defdelegate validate_answer(value, definition), to: Validator, as: :validate

  @doc """
  Validates every answer in a `%{id => raw}` map against a list of
  snapshot definitions. Returns `{:ok, normalised_map}` when all pass,
  or `{:error, %{id => msg}}`.

  Definitions with `required: true` and no entry in the answers map
  produce a "required" error. Extra answer keys not in the snapshot
  are dropped silently — the snapshot is the source of truth.
  """
  @spec validate_answers([map()], map()) ::
          {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate_answers(snapshot, answers) when is_list(snapshot) and is_map(answers) do
    {ok, errs} =
      Enum.reduce(snapshot, {%{}, %{}}, fn defn, {ok_acc, err_acc} ->
        raw = Map.get(answers, defn["id"])

        case validate_raw(raw, defn) do
          {:ok, normalised} -> {Map.put(ok_acc, defn["id"], normalised), err_acc}
          {:error, msg} -> {ok_acc, Map.put(err_acc, defn["id"], msg)}
        end
      end)

    if map_size(errs) == 0, do: {:ok, ok}, else: {:error, errs}
  end

  defp validate_raw(raw, _defn)
       when is_binary(raw) and byte_size(raw) > @max_raw_answer_length do
    {:error, "Answer is too long"}
  end

  defp validate_raw(raw, defn), do: Validator.validate(raw, defn)
end
