defmodule Tymeslot.Profiles.OrganizerContext do
  @moduledoc """
  Resolves organizer context for scheduling pages.

  Given an address (a username, or `<username>/<page>` for one of its booking
  pages), loads the organiser's profile, the meeting types that address
  offers, and assembles the context map consumed by scheduling LiveViews.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.ProfileQueries

  @type username :: String.t()

  @doc """
  Resolves organiser context from an address, including profile and meeting
  types. `username` in the result is the address, so the flow's own links
  stay under it; a page's address comes back in its stored, lowercase form
  (`BookingPages.public_address/1`).

  A page is resolved whether it is published or not: whoever may see a draft
  is the caller's decision (`BookingPages.published?/1`).
  """
  @spec resolve_organizer_context(username()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(address) when is_binary(address) do
    case resolve_profile(address) do
      {:ok, profile} ->
        meeting_types = load_meeting_types(profile)
        profile_with_meeting_types = %{profile | meeting_types: meeting_types}
        {:ok, build_organizer_context(profile_with_meeting_types, address)}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  defp resolve_profile(address) do
    case String.split(address, "/", parts: 2) do
      [username, slug] -> BookingPages.resolve_with_user(username, slug)
      [username] -> ProfileQueries.get_by_username_with_user(username)
    end
  end

  defp load_meeting_types(%{booking_page: %BookingPageSchema{} = page}),
    do: BookingPages.list_meeting_types(page)

  defp load_meeting_types(profile), do: MeetingTypes.get_public_meeting_types(profile.user_id)

  defp build_organizer_context(profile, address) do
    meeting_types = profile.meeting_types
    display_name = profile.full_name || get_user_name_from_profile(profile) || profile.username

    %{
      username: BookingPages.public_address(profile) || address,
      profile: profile,
      user_id: profile.user_id,
      meeting_types: meeting_types,
      page_title: dgettext("booking", "Schedule with %{name}", name: display_name)
    }
  end

  defp get_user_name_from_profile(%{user: %{name: name}}), do: name
  defp get_user_name_from_profile(_arg), do: nil
end
