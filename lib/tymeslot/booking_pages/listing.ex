defmodule Tymeslot.BookingPages.Listing do
  @moduledoc """
  Which meeting types a booking page offers, and which pages each of a
  profile's meeting types is listed on. Reads only; listing a type on a page
  is `Tymeslot.BookingPages.set_meeting_type/3`.
  """

  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.PublicListing
  alias Tymeslot.Profiles.ProfileQueries

  @doc """
  Whether `page` is public: it offers at least one meeting type
  (`list_meeting_types/1`). A page that offers none is a draft, which only
  its owner sees, through the dashboard's preview.
  """
  @spec published?(BookingPageSchema.t()) :: boolean()
  def published?(%BookingPageSchema{} = page), do: list_meeting_types(page) != []

  @doc """
  The meeting types `page` alone lists: hidden from the profile's own page
  and on no other page, so deleting `page` leaves them unlisted everywhere,
  bookable only by their direct links. In the profile's order.
  """
  @spec only_listed_on(BookingPageSchema.t()) :: [MeetingTypeSchema.t()]
  def only_listed_on(%BookingPageSchema{id: page_id} = page) do
    memberships = memberships(page.profile_id)
    sole = MapSet.new([page_id])

    page.profile_id
    |> ProfileQueries.user_id_for_profile()
    |> MeetingTypes.get_all_meeting_types()
    |> Enum.filter(&(&1.is_private and Map.get(memberships, &1.id) == sole))
  end

  @doc """
  The meeting types `page` offers on its start page: listed on it and active,
  then filtered and ordered as `MeetingTypes.get_public_meeting_types/1` treats
  the profile's own page (`Tymeslot.MeetingTypes.PublicListing`).
  """
  @spec list_meeting_types(BookingPageSchema.t()) :: [MeetingTypeSchema.t()]
  def list_meeting_types(%BookingPageSchema{id: page_id}) do
    page_id
    |> BookingPageQueries.list_meeting_types()
    |> PublicListing.offered()
  end

  @doc """
  Whether `page` serves `meeting_type` at `/<username>/<page>/<slug>`: the
  type is listed on it, or it is unlisted everywhere (hidden from
  `/<username>` and on no page), so its direct link is the only way in and
  any of the host's addresses may carry it. A type listed only on
  `/<username>` or on other pages belongs to its own address
  (`Tymeslot.BookingPages.Addresses.meeting_type_path/2`), and booking it
  here would record this page against a type it does not offer. An
  invitation-only type is served by no page: no page offers it, and its
  address is `/<username>/<slug>`.
  """
  @spec serves?(BookingPageSchema.t(), map()) :: boolean()
  def serves?(_page, %{invitation_only: true}), do: false

  def serves?(%BookingPageSchema{id: page_id}, %{id: type_id, is_private: private?})
      when is_integer(type_id) do
    case BookingPageQueries.page_ids_for_meeting_type(type_id) do
      [] -> private? == true
      page_ids -> page_id in page_ids
    end
  end

  def serves?(_page, _meeting_type), do: false

  @doc """
  Which extra pages each of the profile's meeting types is listed on. A type
  on none of them has no key.
  """
  @spec memberships(integer()) :: %{optional(integer()) => MapSet.t(integer())}
  def memberships(profile_id) do
    profile_id
    |> BookingPageQueries.memberships_for_profile()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {type_id, page_ids} -> {type_id, MapSet.new(page_ids)} end)
  end
end
