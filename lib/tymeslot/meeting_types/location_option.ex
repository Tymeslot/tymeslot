defmodule Tymeslot.MeetingTypes.LocationOption do
  @moduledoc """
  Embedded schema for a single location a meeting type can be held at.

  A meeting type carries an ordered list of these. One entry means the
  location is fixed and the booker is simply told what it is; two or more
  means the booker chooses, which is the whole point of the list.

  Each option has a stable `id` (UUID), a `kind` that decides what the
  option *does* at booking time, a host-authored `label` the booker sees,
  and kind-specific config:

    * `video`: binds to one or more of the host's video integrations via
      `video_integration_ids`, in the host's order. With one, choosing the
      option creates the room there; with several, the booker also picks
      which provider, and the first is the one the picker opens on.
    * `in_person`: binds to any number of the host's saved venues via
      `venue_ids`, in the host's order (see `Tymeslot.Venues`). With one,
      the booker is told where the meeting is; with several, the booker
      also picks which, and the first is the one the picker opens on; with
      none, the address is arranged after booking. `details` is not used.
    * `phone`: `details` carries the number to call, unless
      `collect_from_guest` is set, in which case the booker supplies theirs.
    * `custom`: `details` is free text.

  Ownership of the listed integrations and venues is checked where a form
  saves the list, `Tymeslot.MeetingTypes.FormValidation`.

  Host-editable: everything but `id`. Changing the kind clears config that
  no longer applies, the same way `Tymeslot.CustomFields.FieldDefinition`
  does for question types.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ecto.UUID

  @kinds ~w(video in_person phone custom)

  @label_max_length 120
  @details_max_length 500

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :id, :string
    field :kind, :string
    field :label, :string
    field :details, :string
    field :collect_from_guest, :boolean, default: false
    field :video_integration_ids, {:array, :integer}, default: []
    field :venue_ids, {:array, :integer}, default: []
    field :position, :integer, default: 0
  end

  @doc "Build a changeset. Auto-fills `id` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(option, attrs) do
    option
    |> cast(attrs, [
      :id,
      :kind,
      :label,
      :details,
      :collect_from_guest,
      :video_integration_ids,
      :venue_ids,
      :position
    ])
    |> maybe_set_id()
    |> dedupe(:video_integration_ids)
    |> dedupe(:venue_ids)
    |> validate_required([:kind, :label])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:label, max: @label_max_length)
    |> validate_length(:details, max: @details_max_length)
    |> clear_irrelevant_kind_config(option)
    |> clear_in_person_details()
    |> then(fn cs -> if cs.valid?, do: validate_kind_specific(cs), else: cs end)
  end

  @doc "All known location kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The one-line location string written to the meeting, the calendar event
  and the confirmation emails.

  The label alone when there is nothing to add to it, otherwise the label
  with its details in parentheses, so "Our office (12 High Street)" reads
  as one place rather than two fields concatenated.
  """
  @spec display(t() | map()) :: String.t()
  def display(%{label: label, details: details})
      when is_binary(details) and details != "" do
    "#{label} (#{details})"
  end

  def display(%{label: label}), do: label

  defp maybe_set_id(cs) do
    case get_field(cs, :id) do
      id when is_binary(id) and id != "" -> cs
      _other -> put_change(cs, :id, UUID.generate())
    end
  end

  # The same provider or venue twice would be two identical choices for the
  # booker.
  defp dedupe(cs, field) do
    case get_change(cs, field) do
      ids when is_list(ids) -> put_change(cs, field, Enum.uniq(ids))
      _unchanged -> cs
    end
  end

  # When the kind changes, clear config that belongs exclusively to the
  # *previous* kind so a video option demoted to in-person does not keep
  # pointing at an integration that will never be consulted again.
  # `details` survives transitions between the kinds that use it (phone and
  # custom); an in-person option never keeps it, see
  # `clear_in_person_details/1`.
  defp clear_irrelevant_kind_config(cs, old) do
    new_kind = get_field(cs, :kind)

    if new_kind && new_kind != old.kind do
      cs
      |> maybe_clear_video_integration(new_kind)
      |> maybe_clear_venues(new_kind)
      |> maybe_clear_collect_from_guest(new_kind)
    else
      cs
    end
  end

  defp maybe_clear_video_integration(cs, "video"), do: cs
  defp maybe_clear_video_integration(cs, _kind), do: put_change(cs, :video_integration_ids, [])

  defp maybe_clear_venues(cs, "in_person"), do: cs
  defp maybe_clear_venues(cs, _kind), do: put_change(cs, :venue_ids, [])

  defp maybe_clear_collect_from_guest(cs, "phone"), do: cs
  defp maybe_clear_collect_from_guest(cs, _kind), do: put_change(cs, :collect_from_guest, false)

  # An in-person option's address lives in its venues. A `details` value left
  # on one, by an older form or a kind change, would be a second address
  # source that nothing reads, so it is dropped.
  defp clear_in_person_details(cs) do
    if get_field(cs, :kind) == "in_person" and not is_nil(get_field(cs, :details)),
      do: put_change(cs, :details, nil),
      else: cs
  end

  defp validate_kind_specific(cs) do
    case get_field(cs, :kind) do
      "video" -> validate_has_video_integration(cs)
      "phone" -> validate_phone_reachable(cs)
      _kind -> cs
    end
  end

  # `validate_length/3` only looks at changes, and the list's `[]` default is
  # never one, so an option that never named a provider would slip past it.
  defp validate_has_video_integration(cs) do
    case get_field(cs, :video_integration_ids) do
      [_first | _rest] -> cs
      _none -> add_error(cs, :video_integration_ids, "can't be blank", validation: :required)
    end
  end

  # A phone option has to say who rings whom. Either the host publishes a
  # number to call, or the booker is asked for theirs; an option that does
  # neither leaves both parties waiting.
  defp validate_phone_reachable(cs) do
    if get_field(cs, :collect_from_guest) do
      cs
    else
      validate_required(cs, [:details])
    end
  end
end
