defmodule Tymeslot.Security.FieldValidators.MultiSelectValidator do
  @moduledoc "Validates a multi_select answer (list of option keys)."

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(nil, _, opts), do: blank_result(opts)
  def validate([], _, opts), do: blank_result(opts)

  def validate(values, definition, opts) when is_list(values) do
    allowed = MapSet.new(allowed_keys(definition))
    given = MapSet.new(values)
    min = Keyword.get(opts, :min_selections)
    max = Keyword.get(opts, :max_selections)

    cond do
      not Enum.all?(values, &is_binary/1) ->
        {:error, "Selections must be strings"}

      not MapSet.subset?(given, allowed) ->
        {:error, "Some selections are not valid options"}

      min && MapSet.size(given) < min ->
        {:error, "Please choose at least #{min}"}

      max && MapSet.size(given) > max ->
        {:error, "Please choose at most #{max}"}

      true ->
        :ok
    end
  end

  def validate(_, _, _), do: {:error, "Selections must be a list"}

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true),
      do: {:error, "Please choose at least one option"},
      else: :ok
  end

  defp allowed_keys(%{"options" => options}) when is_list(options) do
    Enum.map(options, fn
      %{"key" => k} -> k
      %{key: k} -> k
      _ -> nil
    end)
  end

  defp allowed_keys(_), do: []
end
