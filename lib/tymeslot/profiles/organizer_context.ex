defmodule Tymeslot.Profiles.OrganizerContext do
  @moduledoc """
  Resolves organizer context for scheduling pages.

  Given a username, loads the organiser's profile, active meeting types,
  and assembles the context map consumed by scheduling LiveViews.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.ProfileQueries

  @type username :: String.t()

  @doc """
  Resolves organiser context from a username, including profile and meeting types.
  """
  @spec resolve_organizer_context(username()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    case resolve_profile(username) do
      {:ok, profile} ->
        meeting_types = load_meeting_types(profile)
        profile_with_meeting_types = %{profile | meeting_types: meeting_types}
        {:ok, build_organizer_context(profile_with_meeting_types, username)}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  # A username first, then a booking page's address: a username always wins.
  defp resolve_profile(address) do
    case ProfileQueries.get_by_username_with_user(address) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> BookingPages.resolve_with_user(address)
    end
  end

  defp load_meeting_types(%{booking_page: %BookingPageSchema{} = page}),
    do: BookingPages.list_meeting_types(page)

  defp load_meeting_types(profile), do: MeetingTypes.get_public_meeting_types(profile.user_id)

  defp build_organizer_context(profile, username) do
    meeting_types = profile.meeting_types
    display_name = profile.full_name || get_user_name_from_profile(profile) || username

    %{
      username: username,
      profile: profile,
      user_id: profile.user_id,
      meeting_types: meeting_types,
      page_title: dgettext("booking", "Schedule with %{name}", name: display_name)
    }
  end

  defp get_user_name_from_profile(%{user: %{name: name}}), do: name
  defp get_user_name_from_profile(_arg), do: nil
end
