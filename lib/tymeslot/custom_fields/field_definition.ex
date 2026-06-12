defmodule Tymeslot.CustomFields.FieldDefinition do
  @moduledoc """
  Embedded schema for a single custom-field definition attached to a
  meeting type. Each definition has a stable `id` (UUID), a `type`, a
  host-authored `label`, and type-specific config (`options`, `body`,
  `min`, `max`).

  Host-editable: `type`, `label`, `help_text`, `required`, `options`,
  `body`, `min`, `max`, `position`. Never edited: `id`.

  Changing the type clears type-specific config that no longer applies.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.UUID
  alias Tymeslot.CustomFields.FieldOption

  @types ~w(short_text number single_select multi_select yes_no phone url date time note)

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :id, :string
    field :type, :string
    field :label, :string
    field :help_text, :string
    field :required, :boolean, default: false
    field :position, :integer, default: 0
    field :body, :string
    # `min`/`max` are stored as strings so a single pair of fields can express
    # bounds for numeric questions (`"1"`, `"10"`), date questions
    # (`"2026-01-01"`) and time questions (`"09:00"`). The type-specific
    # validators parse them into the appropriate type at booking time.
    field :min, :string
    field :max, :string

    embeds_many :options, FieldOption, on_replace: :delete
  end

  @doc "Build a changeset. Auto-fills `id` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [:id, :type, :label, :help_text, :required, :position, :body, :min, :max])
    |> cast_embed(:options, with: &FieldOption.changeset/2)
    |> maybe_set_id()
    |> validate_required([:type, :label])
    |> validate_inclusion(:type, @types)
    |> validate_length(:label, max: 120)
    |> validate_length(:help_text, max: 300)
    |> clear_irrelevant_type_config(definition)
    |> then(fn cs -> if cs.valid?, do: validate_type_specific(cs), else: cs end)
  end

  @doc "All known field type strings."
  @spec types() :: [String.t()]
  def types, do: @types

  defp maybe_set_id(cs) do
    case get_field(cs, :id) do
      id when is_binary(id) and id != "" -> cs
      _other -> put_change(cs, :id, UUID.generate())
    end
  end

  @select_types ~w(single_select multi_select)

  # When the type changes, clear config that belongs exclusively to the
  # *previous* type so we don't leak stale data. Fields that are also
  # meaningful for the new type are left untouched — e.g. `options` are
  # kept when switching between select types, and `min`/`max` are kept
  # when switching between bounded types (number/date/time).
  #
  # Host-side UI shows a confirmation dialog before doing this — the
  # data-layer change here is the safety net.
  defp clear_irrelevant_type_config(cs, old) do
    new_type = get_field(cs, :type)
    old_type = old.type

    if new_type && new_type != old_type do
      cs
      |> maybe_clear_options(new_type)
      |> maybe_clear_body(new_type)
      |> maybe_clear_min_max(new_type)
    else
      cs
    end
  end

  defp maybe_clear_options(cs, new_type) when new_type in @select_types, do: cs
  defp maybe_clear_options(cs, _new_type), do: put_change(cs, :options, [])

  defp maybe_clear_body(cs, "note"), do: cs
  defp maybe_clear_body(cs, _new_type), do: put_change(cs, :body, nil)

  @bounded_types ~w(number date time)

  defp maybe_clear_min_max(cs, new_type) when new_type in @bounded_types, do: cs

  defp maybe_clear_min_max(cs, _new_type),
    do: cs |> put_change(:min, nil) |> put_change(:max, nil)

  defp validate_type_specific(cs) do
    case get_field(cs, :type) do
      "single_select" -> select_validations(cs)
      "multi_select" -> select_validations(cs)
      "note" -> validate_required(cs, [:body])
      "number" -> validate_min_le_max(cs, :number)
      "date" -> validate_min_le_max(cs, :date)
      "time" -> validate_min_le_max(cs, :time)
      _type -> cs
    end
  end

  defp select_validations(cs) do
    cs
    |> validate_min_options(2)
    |> validate_length(:options, max: 50)
    |> validate_unique_option_keys()
  end

  defp validate_min_options(cs, min) do
    options = get_field(cs, :options) || []

    if length(options) < min do
      add_error(cs, :options, "must have at least #{min} options")
    else
      cs
    end
  end

  # Option keys are the values persisted on bookings, so duplicates would
  # make stored answers ambiguous. Reject any collision.
  defp validate_unique_option_keys(cs) do
    keys =
      (get_field(cs, :options) || [])
      |> Enum.map(& &1.key)
      |> Enum.reject(&is_nil/1)

    if keys != Enum.uniq(keys) do
      add_error(cs, :options, "must not contain duplicate keys")
    else
      cs
    end
  end

  defp validate_min_le_max(cs, type) do
    case {get_field(cs, :min), get_field(cs, :max)} do
      {nil, _max} -> cs
      {_min, nil} -> cs
      {min, max} -> validate_bound_order(cs, type, min, max)
    end
  end

  defp validate_bound_order(cs, type, min, max) do
    with {:ok, lo} <- parse_bound(type, min),
         {:ok, hi} <- parse_bound(type, max) do
      if bound_le?(type, lo, hi),
        do: cs,
        else: add_error(cs, :max, "must be greater than or equal to min")
    else
      # An unparseable bound skips the min<=max check; the changeset is
      # returned unchanged because the values are not comparable.
      :error -> cs
    end
  end

  defp parse_bound(:number, value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _err -> parse_integer_bound(value)
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_bound(:date, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _err -> :error
    end
  end

  defp parse_bound(:time, value) do
    padded = if length(String.split(value, ":")) == 2, do: value <> ":00", else: value

    case Time.from_iso8601(padded) do
      {:ok, time} -> {:ok, time}
      _err -> :error
    end
  end

  defp parse_integer_bound(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp bound_le?(:number, lo, hi), do: lo <= hi
  defp bound_le?(:date, lo, hi), do: Date.compare(lo, hi) in [:lt, :eq]
  defp bound_le?(:time, lo, hi), do: Time.compare(lo, hi) in [:lt, :eq]
end
