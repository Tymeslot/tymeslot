defmodule Tymeslot.Security.FieldValidators.YesNoValidator do
  @moduledoc "Validates a strict boolean answer for a yes_no field."

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(true, _, _), do: :ok

  def validate(false, _, opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Please tick this box"}, else: :ok
  end

  def validate(nil, _, opts), do: validate(false, %{}, opts)

  def validate(_, _, _), do: {:error, "Answer must be yes or no"}
end
