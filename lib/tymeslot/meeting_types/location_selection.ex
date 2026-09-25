defmodule Tymeslot.MeetingTypes.LocationSelection do
  @moduledoc """
  What a meeting type offers as its locations, and what the booker's choice
  among them means for the meeting that gets written.

  Two responsibilities, deliberately in one place because they are the same
  question asked at two moments:

    * `options/1` — the list the booking page renders. It is also the list
      the host's editor renders, so the two can never disagree about what
      this meeting type offers.

    * `resolve/3` — turns the option id the booker submitted into the
      meeting fields that follow from it: the location string the calendar
      event and confirmation emails show, the kind, and the video
      integration the room will be created on.

  ## The booker submits an id, never a location

  Everything else is derived here from the host's own stored option. A
  forged or stale id resolves to the first option rather than being
  honoured, so the worst a tampered submission achieves is booking a
  location the host already offers.

  The same holds for the video provider a booker picks within a video
  option: it is honoured only when the option lists it, and otherwise the
  option's first provider is used.

  ## Meeting types with no stored list

  `locations` was added after meeting types existed, and rows can still
  reach this module without one: bulk-inserted defaults, seeds, an import.
  Those fall back to the single option their `allow_video` /
  `video_integration_id` pair already describes, which is exactly what such
  a type offered before the list existed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.LocationOption

  @typedoc "The meeting fields that follow from the booker's chosen location."
  @type resolution :: %{
          location: String.t() | nil,
          location_kind: String.t() | nil,
          location_option_id: String.t() | nil,
          video_integration_id: integer() | nil,
          attendee_phone: String.t() | nil
        }

  @doc """
  The meeting type's locations, in the host's order.

  Returns `[]` only when there is no meeting type at all (an ad-hoc booking
  against a bare duration), which callers read as "this booking has no
  configured location".
  """
  @spec options(map() | nil) :: [LocationOption.t()]
  def options(nil), do: []

  def options(%{locations: locations}) when is_list(locations) and locations != [] do
    Enum.sort_by(locations, &(&1.position || 0))
  end

  def options(meeting_type), do: derived_options(meeting_type)

  @doc """
  Whether the booking page has to ask. One location is stated, not chosen.
  """
  @spec choice_required?(map() | nil) :: boolean()
  def choice_required?(meeting_type), do: length(options(meeting_type)) > 1

  @doc "The option with `id`, or the first one when `id` matches nothing."
  @spec fetch(map() | nil, String.t() | nil) :: LocationOption.t() | nil
  def fetch(meeting_type, id) do
    opts = options(meeting_type)

    Enum.find(opts, &(&1.id == id)) || List.first(opts)
  end

  @doc """
  Resolves the booker's choice into meeting attributes.

  `guest_phone` is only consulted for a phone option that asks the booker
  for their number; it is ignored everywhere else, so a submission carrying
  one against a video option cannot smuggle it onto the meeting. Likewise
  `video_integration_id`, the provider picked within a video option, is
  only consulted for a video option.
  """
  @spec resolve(map() | nil, String.t() | nil, String.t() | nil, integer() | String.t() | nil) ::
          resolution()
  def resolve(meeting_type, chosen_id, guest_phone \\ nil, video_integration_id \\ nil) do
    case fetch(meeting_type, chosen_id) do
      nil -> empty_resolution()
      option -> resolution_for(option, guest_phone, video_integration_id)
    end
  end

  @doc """
  The video integration a choice lands on: the one the booker picked when
  the option lists it, otherwise the option's first. Nil for an option that
  is not a video call.
  """
  @spec video_integration_for(LocationOption.t(), integer() | String.t() | nil) ::
          integer() | nil
  def video_integration_for(%LocationOption{kind: "video", video_integration_ids: ids}, chosen) do
    chosen_id = to_integer(chosen)
    if chosen_id in ids, do: chosen_id, else: List.first(ids)
  end

  def video_integration_for(%LocationOption{}, _chosen), do: nil

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp to_integer(_id), do: nil

  @doc """
  The location string for an option, with the booker's own number folded in
  when the option asked for one.
  """
  @spec display(LocationOption.t(), String.t() | nil) :: String.t()
  def display(%LocationOption{collect_from_guest: true, label: label} = option, guest_phone) do
    case normalize_phone(guest_phone) do
      nil -> LocationOption.display(%{option | details: nil})
      phone -> "#{label} (#{phone})"
    end
  end

  def display(%LocationOption{} = option, _guest_phone), do: LocationOption.display(option)

  defp resolution_for(%LocationOption{} = option, guest_phone, video_integration_id) do
    %{
      location: display(option, guest_phone),
      location_kind: option.kind,
      location_option_id: option.id,
      video_integration_id: video_integration_for(option, video_integration_id),
      attendee_phone: collected_phone(option, guest_phone)
    }
  end

  defp empty_resolution do
    %{
      location: nil,
      location_kind: nil,
      location_option_id: nil,
      video_integration_id: nil,
      attendee_phone: nil
    }
  end

  defp collected_phone(%LocationOption{kind: "phone", collect_from_guest: true}, guest_phone),
    do: normalize_phone(guest_phone)

  defp collected_phone(_option, _guest_phone), do: nil

  defp normalize_phone(phone) when is_binary(phone) do
    case String.trim(phone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_phone(_phone), do: nil

  # The single option a meeting type offered before the list existed. The
  # ids are stable strings rather than generated UUIDs: the booking form
  # posts the id back, and a value that changed between render and submit
  # would resolve to "not found" on every submission.
  defp derived_options(%{allow_video: true, video_integration_id: id}) when is_integer(id) do
    [
      %LocationOption{
        id: "legacy-video",
        kind: "video",
        label: dgettext("booking", "Video call"),
        video_integration_ids: [id],
        position: 0
      }
    ]
  end

  defp derived_options(_meeting_type) do
    [
      %LocationOption{
        id: "legacy-in-person",
        kind: "in_person",
        label: dgettext("booking", "In person"),
        position: 0
      }
    ]
  end
end
