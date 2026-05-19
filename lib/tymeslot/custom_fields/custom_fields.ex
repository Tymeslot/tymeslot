defmodule Tymeslot.CustomFields do
  @moduledoc """
  Public API for custom booking fields.

  Hosts attach custom-field definitions to a meeting type; bookers
  answer them during the booking flow. Definitions are snapshotted onto
  each booking at submission time so past bookings stay pinned to the
  questions they were actually asked.
  """

  alias Tymeslot.CustomFields.{Snapshot, Validator}

  @doc "Builds a frozen snapshot of a meeting type's custom-field definitions."
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

        case Validator.validate(raw, defn) do
          {:ok, normalised} -> {Map.put(ok_acc, defn["id"], normalised), err_acc}
          {:error, msg} -> {ok_acc, Map.put(err_acc, defn["id"], msg)}
        end
      end)

    if map_size(errs) == 0, do: {:ok, ok}, else: {:error, errs}
  end
end
