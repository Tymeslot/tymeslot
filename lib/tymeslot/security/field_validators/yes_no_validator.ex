defmodule Tymeslot.Security.FieldValidators.YesNoValidator do
  @moduledoc """
  Validates a yes/no choice answer.

  Both `true` (yes) and `false` (no) are valid answers — neither carries
  consequences. Only a missing answer (`nil`) fails when the field is
  marked required. Any other shape is rejected as a wire-protocol error.
  """

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(true, _definition, _opts), do: :ok
  def validate(false, _definition, _opts), do: :ok

  def validate(nil, _definition, opts) do
    if Keyword.get(opts, :required, false), do: {:error, "Answer is required"}, else: :ok
  end

  def validate(_value, _definition, _opts), do: {:error, "Answer must be yes or no"}
end
