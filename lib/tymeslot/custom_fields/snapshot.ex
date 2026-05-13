defmodule Tymeslot.CustomFields.Snapshot do
  @moduledoc """
  Builds an immutable, plain-map snapshot of a meeting type's custom
  field definitions to persist on a booking. The snapshot is what the
  booker actually saw at the time of submission.

  Always plain string-keyed maps — never embedded schema structs — so
  that read-time consumers (LiveView, emails, ICS) never depend on
  Ecto runtime semantics.
  """

  alias Tymeslot.CustomFields.FieldDefinition

  @doc "Builds a snapshot from a meeting type struct or map."
  @spec from_meeting_type(map()) :: [map()]
  def from_meeting_type(%{custom_fields: defs}) when is_list(defs), do: from_definitions(defs)
  def from_meeting_type(_), do: []

  @doc "Normalises a list of definitions (struct or map) to a list of plain maps."
  @spec from_definitions([FieldDefinition.t() | map()]) :: [map()]
  def from_definitions(defs) do
    defs
    |> Enum.sort_by(&position/1)
    |> Enum.map(&to_plain_map/1)
  end

  defp position(%FieldDefinition{position: p}), do: p || 0
  defp position(%{"position" => p}), do: p || 0
  defp position(_), do: 0

  defp to_plain_map(%FieldDefinition{} = d) do
    raw = %{
      "id" => d.id,
      "type" => d.type,
      "label" => d.label,
      "help_text" => d.help_text,
      "required" => d.required,
      "position" => d.position,
      "options" => Enum.map(d.options || [], fn o -> %{"key" => o.key, "label" => o.label} end),
      "body" => d.body,
      "min" => d.min,
      "max" => d.max
    }

    drop_nils(raw)
  end

  defp to_plain_map(map) when is_map(map) do
    stringified = Enum.into(map, %{}, fn {k, v} -> {to_string(k), v} end)
    drop_nils(stringified)
  end

  defp drop_nils(map), do: :maps.filter(fn _, v -> not is_nil(v) end, map)
end
