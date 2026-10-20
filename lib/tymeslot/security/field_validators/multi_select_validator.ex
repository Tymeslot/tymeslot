defmodule Tymeslot.Security.FieldValidators.MultiSelectValidator do
  @moduledoc "Validates a multi_select answer (list of option keys)."

  use Gettext, backend: TymeslotWeb.Gettext

  @spec validate(any(), map(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, definition, opts \\ [])

  def validate(nil, _definition, opts), do: blank_result(opts)
  def validate([], _definition, opts), do: blank_result(opts)

  def validate(values, definition, opts) when is_list(values) do
    allowed = MapSet.new(allowed_keys(definition))
    given = MapSet.new(values)
    min = Keyword.get(opts, :min_selections)
    max = Keyword.get(opts, :max_selections)

    cond do
      not Enum.all?(values, &is_binary/1) ->
        {:error, dgettext("errors_input", "Selections must be strings")}

      not MapSet.subset?(given, allowed) ->
        {:error, dgettext("errors_input", "Some selections are not valid options")}

      min && MapSet.size(given) < min ->
        {:error, dgettext("errors_input", "Please choose at least %{min}", min: min)}

      max && MapSet.size(given) > max ->
        {:error, dgettext("errors_input", "Please choose at most %{max}", max: max)}

      true ->
        :ok
    end
  end

  def validate(_value, _definition, _opts),
    do: {:error, dgettext("errors_input", "Selections must be a list")}

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true),
      do: {:error, dgettext("errors_input", "Please choose at least one option")},
      else: :ok
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
