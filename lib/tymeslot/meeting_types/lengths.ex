defmodule Tymeslot.MeetingTypes.Lengths do
  @moduledoc """
  The lengths a meeting type offers the booker.

  A meeting type always has its own `duration_minutes`. It may also offer
  further lengths (`extra_lengths_minutes`), and the booker then picks one in
  a step of its own before choosing a time.

  Everything on the booking path that asks "how long is *this* booking" goes
  through here, via `Tymeslot.Availability.Offer.duration_minutes/3`: the
  month grid, the week strip, the slot computation, the booking submit and
  the reschedule schedule check. That single resolver is what keeps the grid
  a time was offered from and the grid it is checked against the same one,
  and a length the type does not offer resolves to the primary duration
  rather than being honoured.

  ## What deliberately stays on the primary duration

  Not every reader of `duration_minutes` is answering that question, and the
  ones below are left alone on purpose:

    * **Price.** A type carries one `price_cents` for every length it offers.
      A host who wants to charge more for longer meetings makes them separate
      types; charging per length would need a price per length and a payment
      flow that knows which one was picked. The meeting type form says so
      where the lengths are edited.
    * **Polls** (`Tymeslot.Polls`). A poll asks a group to agree on one slot,
      so its length is settled by the host before the candidates go out.
    * **The Rhythm type card's default icon**
      (`Themes.Rhythm.Scheduling.Components.OverviewComponent`). It belongs to
      the type, and is rendered before any length exists to key it to.
    * **The dashboard's own forms** — the meeting type form, the poll form,
      the service settings — which edit or preselect the primary duration and
      are not booking anything.
    * **A reschedule whose booked length the host has since removed**
      (`Tymeslot.Bookings.Validation.prepare_new_times/4`). The meeting keeps
      its own length; only the schedule check falls back.

  ## Group types offer one length

  Everyone in a group slot shares one meeting row, so its length cannot be
  each booker's choice. The changeset refuses further lengths on a group type
  (`validate_changeset/1`), and `offered/1` ignores any a group type still
  carries, so the booking flow never asks for one.

  Downstream systems — emails, calendar entries, video rooms, webhooks,
  payments — read the booking's own `meetings.duration` or its times, so they
  see the chosen length without knowing this module exists.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset

  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.Validation.Constraints

  @doc """
  Every duration the type offers, in minutes, ascending and without repeats.
  """
  @spec offered(MeetingType.t() | map()) :: [pos_integer()]
  def offered(%{duration_minutes: primary} = meeting_type) when is_integer(primary) do
    [primary | extras(meeting_type)]
    |> Enum.uniq()
    |> Enum.sort()
  end

  def offered(_meeting_type), do: []

  @doc "Whether the booker has more than one duration to choose from."
  @spec multiple?(MeetingType.t() | map() | nil) :: boolean()
  def multiple?(nil), do: false
  def multiple?(meeting_type), do: length(offered(meeting_type)) > 1

  @doc "Whether `minutes` is one of the durations the type offers."
  @spec offers?(MeetingType.t() | map() | nil, term()) :: boolean()
  def offers?(nil, _minutes), do: false

  def offers?(meeting_type, minutes) when is_integer(minutes),
    do: minutes in offered(meeting_type)

  def offers?(_meeting_type, _minutes), do: false

  @doc """
  The duration a booking of this type lasts: `minutes` when the type offers
  it, otherwise the type's own `duration_minutes`.
  """
  @spec resolve(MeetingType.t() | map(), term()) :: pos_integer() | nil
  def resolve(meeting_type, minutes) do
    if offers?(meeting_type, minutes), do: minutes, else: Map.get(meeting_type, :duration_minutes)
  end

  @doc """
  Parses a duration the booker chose, as it arrives in a URL or an event:
  `"45"`, `"45min"` or an integer. Anything else is `nil`.
  """
  @spec parse(term()) :: pos_integer() | nil
  def parse(minutes) when is_integer(minutes) and minutes > 0, do: minutes

  def parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {minutes, rest} when minutes > 0 and rest in ["", "min"] -> minutes
      _other -> nil
    end
  end

  def parse(_value), do: nil

  @doc """
  Validates `extra_lengths_minutes` on a meeting type changeset. Each further
  duration obeys the same range as `duration_minutes`, none may repeat another
  (the booker would see the same choice twice), together with
  `duration_minutes` they stay within the per-type maximum, and a group type
  has none.

  The group refusal is a msgid of the `errors` domain on `:max_participants`,
  like the schema's other group rules.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    extras = get_field(changeset, :extra_lengths_minutes) || []
    primary = get_field(changeset, :duration_minutes)
    range = Constraints.duration_minutes_range()
    max = Constraints.max_lengths_per_meeting_type()

    cond do
      not Enum.all?(extras, &(is_integer(&1) and &1 in range)) ->
        add_error(
          changeset,
          :extra_lengths_minutes,
          "must each be between %{min} and %{max} minutes",
          min: range.first,
          max: range.last
        )

      length(Enum.uniq([primary | extras])) != length(extras) + 1 ->
        add_error(changeset, :extra_lengths_minutes, "must not repeat a duration")

      length(extras) + 1 > max ->
        add_error(changeset, :extra_lengths_minutes, "allows at most %{max} durations", max: max)

      extras != [] and group?(get_field(changeset, :max_participants)) ->
        add_error(
          changeset,
          :max_participants,
          dgettext_noop("errors", "group bookings cannot offer more than one duration")
        )

      true ->
        changeset
    end
  end

  defp extras(meeting_type) do
    case {Map.get(meeting_type, :extra_lengths_minutes), Map.get(meeting_type, :max_participants)} do
      {_list, max} when is_integer(max) and max > 1 -> []
      {list, _max} when is_list(list) -> Enum.filter(list, &is_integer/1)
      _none -> []
    end
  end

  defp group?(max), do: is_integer(max) and max > 1
end
