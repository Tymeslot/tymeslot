defmodule Tymeslot.Security.FieldValidators.NoteAckValidator do
  @moduledoc """
  Validates the acknowledgement payload for a `note` custom field. The
  shape `%{"confirmed" => true, "confirmed_at" => <iso8601>}` is the
  contract between the booking engine and the snapshot.
  """

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(%{"confirmed" => true, "confirmed_at" => iso}, _, _)
      when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, _, 0} -> :ok
      {:ok, _, _} -> {:error, "Confirmation timestamp must be UTC"}
      _ -> {:error, "Confirmation timestamp is invalid"}
    end
  end

  def validate(_, _, _), do: {:error, "Please acknowledge to continue"}
end
