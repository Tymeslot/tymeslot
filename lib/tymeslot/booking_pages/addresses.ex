defmodule Tymeslot.BookingPages.Addresses do
  @moduledoc """
  The public addresses of a profile's start pages and meeting types, as the
  booking pages lay them out under `/<username>`. Reads only.
  """

  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.BookingPages.Listing
  alias Tymeslot.MeetingTypes

  @doc """
  The address a profile's start page is at, without the leading slash: its
  username, or `<username>/<slug>` for a profile resolved through a page.
  """
  @spec public_address(map() | nil) :: String.t() | nil
  def public_address(%{booking_page: %BookingPageSchema{slug: slug}, username: username})
      when is_binary(username),
      do: username <> "/" <> slug

  def public_address(%{username: username}), do: username
  def public_address(_no_profile), do: nil

  @doc "A page as the dashboard lists it: its name, then its address under `username`."
  @spec name_and_address(BookingPageSchema.t(), String.t() | nil) :: String.t()
  def name_and_address(%BookingPageSchema{name: name, slug: slug}, username),
    do: "#{name} · /#{username}/#{slug}"

  @doc """
  The one address `meeting_type` is booked at, as a path: under the oldest
  page listing it when the profile's own page does not (`home_page/1`),
  otherwise `/<username>/<slug>`, which also serves a type listed nowhere
  as its direct link. `profile` is the owner's, through a page or not.
  """
  @spec meeting_type_path(map(), map()) :: String.t()
  def meeting_type_path(%{username: username}, meeting_type),
    do: path_under(username, home_page(meeting_type), meeting_type)

  @doc """
  `meeting_type_path/2` for each of `meeting_types`, by id, from one look at
  the profile's pages rather than one per type. For a list of types.
  """
  @spec meeting_type_paths(map(), [map()]) :: %{optional(integer()) => String.t()}
  def meeting_type_paths(%{id: profile_id} = profile, meeting_types),
    do:
      meeting_type_paths(
        profile,
        meeting_types,
        BookingPageQueries.list_for_profile(profile_id),
        Listing.memberships(profile_id)
      )

  @doc """
  `meeting_type_paths/2` from the profile's pages, oldest first as
  `Tymeslot.BookingPages.list/1` returns them, and their
  `Listing.memberships/1`, for a caller already holding both.
  """
  @spec meeting_type_paths(map(), [map()], [BookingPageSchema.t()], map()) ::
          %{optional(integer()) => String.t()}
  def meeting_type_paths(%{username: username}, meeting_types, pages, memberships) do
    Map.new(meeting_types, fn type ->
      listed_on = Map.get(memberships, type.id, MapSet.new())
      home = if has_page_home?(type), do: Enum.find(pages, &MapSet.member?(listed_on, &1.id))
      {type.id, path_under(username, home, type)}
    end)
  end

  defp path_under(username, nil, type),
    do: "/#{username}/#{MeetingTypes.effective_slug(type)}"

  defp path_under(username, %BookingPageSchema{slug: page_slug}, type),
    do: "/#{username}/#{page_slug}/#{MeetingTypes.effective_slug(type)}"

  @doc """
  The page `meeting_type` belongs to: the oldest page listing it, when it is
  hidden from the profile's own page (`is_private`). nil for a type the
  profile's own page lists, one listed on no page at all, and an
  invitation-only type, which no page offers (`PublicListing.offered/1`) and
  so lives at `/<username>/<slug>` however it is listed.
  """
  @spec home_page(map()) :: BookingPageSchema.t() | nil
  def home_page(%{invitation_only: true}), do: nil

  def home_page(%{is_private: true, id: id}) when is_integer(id),
    do: BookingPageQueries.first_for_meeting_type(id)

  def home_page(_listed_on_own_page), do: nil

  defp has_page_home?(%{invitation_only: true}), do: false
  defp has_page_home?(type), do: type.is_private

  @doc """
  The address, without the leading slash, to send someone back to for
  `meeting`: `<username>/<page>` while the page it came through exists and
  is public, otherwise `username` (the host's own page).
  """
  @spec address_for_meeting(map(), String.t() | nil) :: String.t() | nil
  def address_for_meeting(%{booking_page_id: page_id}, username)
      when is_integer(page_id) and is_binary(username) do
    with %BookingPageSchema{} = page <- BookingPageQueries.get(page_id),
         true <- Listing.published?(page) do
      username <> "/" <> page.slug
    else
      _gone_or_draft -> username
    end
  end

  def address_for_meeting(_meeting, username), do: username
end
