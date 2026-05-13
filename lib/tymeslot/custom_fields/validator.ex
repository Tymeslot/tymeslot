defmodule Tymeslot.CustomFields.Validator do
  @moduledoc """
  Validates a booker's answer for a single custom-field definition (or
  the snapshot copy of one). Dispatches by `definition["type"]` to the
  matching `Tymeslot.Security.FieldValidators.*` module. Returns the
  normalised value on success.
  """

  alias Tymeslot.Security.FieldValidators

  @type definition :: map()
  @type result :: {:ok, term()} | {:error, String.t()}

  @spec validate(any(), definition()) :: result()
  def validate(value, %{"type" => type} = definition) do
    required? = Map.get(definition, "required", false)
    opts = [required: required?]

    case type do
      "short_text" -> chain(FieldValidators.TextValidator, value, opts)
      "number" -> chain(FieldValidators.NumberValidator, value, opts_with_min_max(definition))
      "phone" -> chain(FieldValidators.PhoneValidator, value, opts)
      "url" -> chain(FieldValidators.UrlValidator, value, opts)
      "date" -> chain(FieldValidators.DateValidator, value, opts_with_min_max(definition))
      "time" -> chain(FieldValidators.TimeValidator, value, opts)
      "single_select" -> chain3(FieldValidators.SelectValidator, value, definition, opts)
      "multi_select" -> chain3(FieldValidators.MultiSelectValidator, value, definition, opts)
      "yes_no" -> chain3(FieldValidators.YesNoValidator, value, definition, opts)
      "note" -> chain3(FieldValidators.NoteAckValidator, value, definition, opts)
      _other -> {:error, "Unknown field type"}
    end
  end

  defp chain(mod, value, opts) do
    case mod.validate(value, opts) do
      :ok -> {:ok, value}
      {:error, _reason} = e -> e
    end
  end

  defp chain3(mod, value, definition, opts) do
    case mod.validate(value, definition, opts) do
      :ok -> {:ok, value}
      {:error, _reason} = e -> e
    end
  end

  defp opts_with_min_max(definition) do
    [required: Map.get(definition, "required", false)]
    |> maybe_put(:min, Map.get(definition, "min"))
    |> maybe_put(:max, Map.get(definition, "max"))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
