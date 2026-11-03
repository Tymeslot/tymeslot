defmodule Tymeslot.MeetingTypes.Duplication do
  @moduledoc """
  The attributes for a copy of a meeting type, written by
  `Tymeslot.MeetingTypes.duplicate_meeting_type/1`.

  A copy carries every setting of its source except the ones that identify
  the source or would make the copy live before its owner has looked at it:

    * the name gains a "(copy)" suffix, the first of "<name> (copy)",
      "<name> (copy) 2", ... that none of the owner's meeting types holds,
      since names are unique per owner;
    * the custom slug is dropped, so a private type's secret link keeps
      reaching the source alone, and the copy's URL derives from its name;
    * the copy starts switched off, so a half-edited duplicate never appears
      on the booking page, and is never archived.

  The dates of a fixed-dates type are not copied: a group type's planned
  sessions are meetings in their own right, with their own sign-ups, and a
  one-to-one type's offered times are the source's own list. The copy starts
  with none, for its owner to add.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Validation.Constraints

  # The settings a copy takes over unchanged. Every schema field is either
  # here, in `@copied_embeds`, or in `@not_copied`; `field_partition/0` lets a
  # test hold that, so a field added later cannot be left out of copies
  # without anyone deciding so.
  @copied_fields [
    :description,
    :duration_minutes,
    :extra_lengths_minutes,
    :slot_interval_minutes,
    :icon,
    :is_private,
    :show_as_free,
    :sort_order,
    :user_id,
    :calendar_integration_id,
    :availability_schedule_id,
    :target_calendar_id,
    :reminder_config,
    :payment_required,
    :price_cents,
    :max_participants,
    :fixed_dates,
    :one_off,
    :show_seat_availability,
    :last_spots_threshold,
    :max_guests_per_booking,
    :allow_guests,
    :requires_approval,
    :approval_window_hours,
    :max_bookings_per_day,
    :max_bookings_per_week,
    :max_bookings_per_month,
    :buffer_before_minutes,
    :buffer_after_minutes,
    :min_advance_hours,
    :advance_booking_days
  ]

  @copied_embeds [:custom_fields, :attachments, :locations]

  # Left out on purpose: the identity and timestamps of the row, the name and
  # state the copy is given (`copy_attrs/1`), the slug (see the moduledoc),
  # and `allow_video` and `video_integration_id`, which the changeset derives
  # from the copied locations.
  @not_copied [
    :id,
    :name,
    :slug,
    :is_active,
    :is_archived,
    :allow_video,
    :video_integration_id,
    :inserted_at,
    :updated_at
  ]

  @doc false
  @spec field_partition() :: %{copied: [atom()], not_copied: [atom()]}
  def field_partition, do: %{copied: @copied_fields ++ @copied_embeds, not_copied: @not_copied}

  @doc """
  The create attributes for a copy of `source`.

  Embedded lists keep their ids: a booking refers to a location or a question
  by an id scoped to its own meeting type, so the copy's ids never meet the
  source's.
  """
  @spec copy_attrs(MeetingTypeSchema.t()) :: map()
  def copy_attrs(%MeetingTypeSchema{} = source) do
    source
    |> Map.take(@copied_fields)
    |> Map.merge(embed_attrs(source))
    |> Map.merge(%{name: copy_name(source), is_active: false, is_archived: false})
  end

  # An empty list is left out rather than passed: the changeset reads a
  # supplied empty `locations` as the owner removing every location, and
  # refuses it, where a type stored without any (one predating locations)
  # must copy as it is.
  defp embed_attrs(source) do
    for field <- @copied_embeds, (embeds = Map.fetch!(source, field)) != [], into: %{} do
      {field, Enum.map(embeds, &struct_params/1)}
    end
  end

  # `cast_embed/3` takes params, not structs.
  defp struct_params(%_module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Map.new(fn {key, value} -> {key, nested_params(value)} end)
  end

  defp nested_params(list) when is_list(list), do: Enum.map(list, &nested_params/1)

  defp nested_params(%module{} = struct) do
    if function_exported?(module, :__schema__, 1), do: struct_params(struct), else: struct
  end

  defp nested_params(value), do: value

  # One more candidate than there are names guarantees a free one, so the
  # search is bounded by the owner's meeting type count.
  defp copy_name(%{name: name, user_id: user_id}) do
    taken =
      user_id
      |> MeetingTypeQueries.list_all_meeting_types()
      |> MapSet.new(& &1.name)

    1..(MapSet.size(taken) + 1)
    |> Enum.map(&with_copy_suffix(name, &1))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # The source name is shortened rather than the suffix, so every candidate
  # stays distinct and within the length limit.
  defp with_copy_suffix(name, number) do
    suffix = " " <> copy_suffix(number)
    max = Constraints.name_length_range().last

    String.slice(name, 0, max - String.length(suffix)) <> suffix
  end

  defp copy_suffix(1), do: dgettext("dashboard_meeting_types", "(copy)")

  defp copy_suffix(number),
    do: dgettext("dashboard_meeting_types", "(copy) %{number}", number: number)
end
