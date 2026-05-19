defmodule Tymeslot.Security.FieldValidators.NoteAckValidator do
  @moduledoc """
  Validates the acknowledgement payload for a `note` custom field. The
  shape `%{"confirmed" => true, "confirmed_at" => <iso8601>}` is the
  contract between the booking engine and the snapshot.
  """

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(%{"confirmed" => true, "confirmed_at" => iso}, _definition, _opts)
      when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, _dt, 0} -> :ok
      {:ok, _dt, _offset} -> {:error, "Confirmation timestamp must be UTC"}
      _err -> {:error, "Confirmation timestamp is invalid"}
    end
  end

  def validate(_value, _definition, _opts), do: {:error, "Please acknowledge to continue"}
end
