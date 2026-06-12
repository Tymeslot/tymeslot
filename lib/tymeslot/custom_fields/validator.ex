defmodule Tymeslot.CustomFields.Validator do
  @moduledoc """
  Validates a booker's answer for a single custom-field definition (or
  the snapshot copy of one). Dispatches by `definition["type"]` to the
  matching `Tymeslot.Security.FieldValidators.*` module. Returns the
  normalised value on success.
  """

  alias Tymeslot.Security.FieldValidators
  alias Tymeslot.Security.FieldValidators.MultiSelectValidator
  alias Tymeslot.Security.FieldValidators.NoteAckValidator

  @type definition :: map()
  @type result :: {:ok, term()} | {:error, String.t()}

  # Defensive ceiling on any single text-like answer we persist to JSONB.
  # Individual validators enforce tighter, type-appropriate caps; this is the
  # last-resort bound that keeps a crafted payload from bloating the row.
  @max_answer_length 2_000

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
      "time" -> chain(FieldValidators.TimeValidator, value, opts_with_min_max(definition))
      "single_select" -> chain3(FieldValidators.SelectValidator, value, definition, opts)
      "multi_select" -> validate_multi_select(value, definition, opts)
      "yes_no" -> chain3(FieldValidators.YesNoValidator, value, definition, opts)
      "note" -> validate_note(value, definition, opts)
      _other -> {:error, "Unknown field type"}
    end
  end

  defp chain(mod, value, opts) do
    case mod.validate(value, opts) do
      :ok -> bound_text(value)
      {:error, _reason} = e -> e
    end
  end

  defp chain3(mod, value, definition, opts) do
    case mod.validate(value, definition, opts) do
      :ok -> bound_text(value)
      {:error, _reason} = e -> e
    end
  end

  # multi_select stores the validated keys de-duplicated and restricted to the
  # canonical option set, so a flood of duplicate or stray keys can't bloat the
  # stored payload.
  defp validate_multi_select(value, definition, opts) do
    case MultiSelectValidator.validate(value, definition, opts) do
      :ok -> {:ok, canonical_keys(value, definition)}
      {:error, _reason} = e -> e
    end
  end

  # The acknowledgement timestamp is authoritative server-side: a client may
  # send any `confirmed_at`, but on success we stamp `DateTime.utc_now/0` so a
  # forged or back-dated value never reaches the snapshot.
  defp validate_note(value, definition, opts) do
    case NoteAckValidator.validate(value, definition, opts) do
      :ok -> {:ok, stamp_note(value)}
      {:error, _reason} = e -> e
    end
  end

  defp stamp_note(%{"confirmed" => true} = value) do
    Map.put(value, "confirmed_at", DateTime.to_iso8601(DateTime.utc_now()))
  end

  defp stamp_note(value), do: value

  defp canonical_keys(values, definition) when is_list(values) do
    allowed = allowed_keys(definition)

    values
    |> Enum.filter(&(&1 in allowed))
    |> Enum.uniq()
  end

  defp canonical_keys(value, _definition), do: value

  defp allowed_keys(%{"options" => options}) when is_list(options) do
    Enum.flat_map(options, fn
      %{"key" => k} when is_binary(k) -> [k]
      %{key: k} when is_binary(k) -> [k]
      _opt -> []
    end)
  end

  defp allowed_keys(_definition), do: []

  defp bound_text(value) when is_binary(value) do
    if String.length(value) > @max_answer_length,
      do: {:error, "Answer is too long"},
      else: {:ok, value}
  end

  defp bound_text(value), do: {:ok, value}

  defp opts_with_min_max(definition) do
    [required: Map.get(definition, "required", false)]
    |> maybe_put(:min, Map.get(definition, "min"))
    |> maybe_put(:max, Map.get(definition, "max"))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
