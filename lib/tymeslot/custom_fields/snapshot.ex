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
  def from_meeting_type(_meeting_type), do: []

  @doc "Normalises a list of definitions (struct or map) to a list of plain maps."
  @spec from_definitions([FieldDefinition.t() | map()]) :: [map()]
  def from_definitions(defs) do
    defs
    |> Enum.sort_by(&position/1)
    |> Enum.map(&to_plain_map/1)
  end

  @doc """
  `snapshot` with the texts of each question it shares with `meeting_type`
  (by id) taken from the meeting type: the label, help text, body and the
  options' labels (by key). Everything else, and any question the meeting
  type no longer has, is kept as it is.

  Used to write a booking's snapshot in the organiser's original wording
  whichever language the booker saw, and the attendee's copy in theirs
  (`Tymeslot.ContentTranslations.AttendeeTexts`).
  """
  @spec overlay_texts([map()], map()) :: [map()]
  def overlay_texts(snapshot, %{custom_fields: defs}) when is_list(snapshot) and is_list(defs) do
    by_id = Map.new(defs, &{&1.id, &1})

    Enum.map(snapshot, fn
      %{"id" => id} = field when is_map_key(by_id, id) -> overlay(field, by_id[id])
      field -> field
    end)
  end

  def overlay_texts(snapshot, _meeting_type), do: snapshot

  defp overlay(field, %FieldDefinition{} = definition) do
    labels = Map.new(definition.options || [], &{&1.key, &1.label})

    field
    |> Map.merge(
      drop_nils(%{
        "label" => definition.label,
        "help_text" => definition.help_text,
        "body" => definition.body
      })
    )
    |> overlay_options(labels)
  end

  defp overlay(field, _not_a_definition), do: field

  defp overlay_options(%{"options" => options} = field, labels) when is_list(options) do
    options =
      Enum.map(options, fn
        %{"key" => key} = option when is_map_key(labels, key) ->
          Map.put(option, "label", labels[key])

        option ->
          option
      end)

    Map.put(field, "options", options)
  end

  defp overlay_options(field, _labels), do: field

  defp position(%FieldDefinition{position: p}), do: p || 0
  defp position(%{"position" => p}), do: p || 0
  defp position(%{position: p}), do: p || 0
  defp position(_field), do: 0

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

  defp drop_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
