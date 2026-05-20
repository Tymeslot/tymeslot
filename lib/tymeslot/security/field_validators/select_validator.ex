defmodule Tymeslot.Security.FieldValidators.SelectValidator do
  @moduledoc """
  Validates a `single_select` custom-field answer against the option keys
  declared on the field definition (or its snapshot).
  """

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(nil, _definition, opts), do: blank_result(opts)
  def validate("", _definition, opts), do: blank_result(opts)

  def validate(value, definition, _opts) when is_binary(value) do
    if value in allowed_keys(definition) do
      :ok
    else
      {:error, "Please choose one of the available options"}
    end
  end

  def validate(_value, _definition, _opts), do: {:error, "Selection must be a single option"}

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true), do: {:error, "Please choose an option"}, else: :ok
  end

  defp allowed_keys(%{"options" => options}) when is_list(options) do
    Enum.map(options, fn
      %{"key" => k} -> k
      %{key: k} -> k
      _opt -> nil
    end)
  end

  defp allowed_keys(_definition), do: []
end
