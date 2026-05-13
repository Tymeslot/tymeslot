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
    field :min, :integer
    field :max, :integer

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
    |> validate_type_specific()
  end

  @doc "All known field type strings."
  @spec types() :: [String.t()]
  def types, do: @types

  defp maybe_set_id(cs) do
    case get_field(cs, :id) do
      id when is_binary(id) and id != "" -> cs
      _ -> put_change(cs, :id, UUID.generate())
    end
  end

  # When the type changes, clear config from the previous type so we don't
  # leak stale `options` after switching to `short_text`, or stale `min`
  # after switching to `note`. Host-side UI shows a confirmation dialog
  # before doing this — the data-layer change here is the safety net.
  defp clear_irrelevant_type_config(cs, old) do
    new_type = get_field(cs, :type)
    old_type = old.type

    if new_type && new_type != old_type do
      cs
      |> put_change(:options, [])
      |> put_change(:body, nil)
      |> put_change(:min, nil)
      |> put_change(:max, nil)
    else
      cs
    end
  end

  defp validate_type_specific(cs) do
    case get_field(cs, :type) do
      "single_select" -> cs |> validate_min_options(2) |> validate_length(:options, max: 50)
      "multi_select" -> cs |> validate_min_options(2) |> validate_length(:options, max: 50)
      "note" -> validate_required(cs, [:body])
      "number" -> validate_min_le_max(cs)
      "date" -> validate_min_le_max(cs)
      _ -> cs
    end
  end

  defp validate_min_options(cs, min) do
    options = get_field(cs, :options) || []

    if length(options) < min do
      add_error(cs, :options, "must have at least #{min} options")
    else
      cs
    end
  end

  defp validate_min_le_max(cs) do
    case {get_field(cs, :min), get_field(cs, :max)} do
      {nil, _} -> cs
      {_, nil} -> cs
      {a, b} when a <= b -> cs
      _ -> add_error(cs, :max, "must be greater than or equal to min")
    end
  end
end
