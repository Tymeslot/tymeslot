defmodule Tymeslot.MeetingTypes.GroupLocationRule do
  @moduledoc """
  Where a group meeting type may be held.

  Everyone booked into a group slot shares one meeting row, so the slot's
  location is fixed by whichever seat creates it and never revisited for the
  seats that follow (`Tymeslot.Bookings.SeatEffects.slot_attrs/2`). A
  location that depends on the booker would therefore be decided by the
  first booker for everybody else. A group type has to say in advance where
  the meeting is, with nothing for the booker to choose or supply:

    * exactly one location;
    * a video call on exactly one provider;
    * in person at exactly one saved venue (no venue means the address is
      arranged after booking, with one booker, which a shared slot cannot
      do);
    * a phone call on a number the host publishes, never one the booker
      gives;
    * anything else ("custom") as written.

  A location passing this rule offers no choice by
  `Tymeslot.MeetingTypes.LocationSelection.choice_required?/3`, so the
  booking page never renders its picker for a group type. The meeting-type
  changeset enforces the rule and the dashboard form asks it before letting
  the host make a change that would break it.
  """

  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.LocationSelection

  @typedoc "Why a set of locations cannot be a group type's."
  @type reason ::
          :not_single_location
          | :provider_choice
          | :venue_choice
          | :address_after_booking
          | :booker_phone

  @doc """
  Checks the locations a meeting type offers, in the shape
  `LocationSelection.options/1` returns them.
  """
  @spec check([LocationOption.t()]) :: :ok | {:error, reason()}
  def check([option]), do: check_option(option)
  def check(_none_or_several), do: {:error, :not_single_location}

  @doc """
  Checks what a meeting type offers, including the single option a type with
  no stored list falls back to (`LocationSelection.options/1`).
  """
  @spec check_meeting_type(map()) :: :ok | {:error, reason()}
  def check_meeting_type(meeting_type), do: meeting_type |> LocationSelection.options() |> check()

  defp check_option(%LocationOption{kind: "video", video_integration_ids: [_one]}), do: :ok
  defp check_option(%LocationOption{kind: "video"}), do: {:error, :provider_choice}

  defp check_option(%LocationOption{kind: "in_person", venue_ids: [_one]}), do: :ok

  defp check_option(%LocationOption{kind: "in_person", venue_ids: ids})
       when ids in [nil, []],
       do: {:error, :address_after_booking}

  defp check_option(%LocationOption{kind: "in_person"}), do: {:error, :venue_choice}

  defp check_option(%LocationOption{kind: "phone", collect_from_guest: true}),
    do: {:error, :booker_phone}

  defp check_option(%LocationOption{}), do: :ok
end
