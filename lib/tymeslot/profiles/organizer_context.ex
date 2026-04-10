defmodule Tymeslot.Profiles.OrganizerContext do
  @moduledoc """
  Resolves organizer context for scheduling pages.

  Given a username, loads the organiser's profile, active meeting types,
  and assembles the context map consumed by scheduling LiveViews.
  """

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.ProfileQueries

  @type username :: String.t()

  @doc """
  Resolves organiser context from a username, including profile and meeting types.
  """
  @spec resolve_organizer_context(username()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    case ProfileQueries.get_by_username_with_user(username) do
      {:ok, profile} ->
        meeting_types = load_active_meeting_types(profile.user_id)
        profile_with_meeting_types = %{profile | meeting_types: meeting_types}
        {:ok, build_organizer_context(profile_with_meeting_types, username)}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  defp load_active_meeting_types(user_id) do
    MeetingTypes.get_active_meeting_types(user_id)
  end

  defp build_organizer_context(profile, username) do
    meeting_types = meeting_types_for_profile(profile)
    display_name = profile.full_name || get_user_name_from_profile(profile) || username

    %{
      username: username,
      profile: profile,
      user_id: profile.user_id,
      meeting_types: meeting_types,
      page_title: "Schedule with #{display_name}"
    }
  end

  defp get_user_name_from_profile(%{user: %{name: name}}), do: name
  defp get_user_name_from_profile(_arg), do: nil

  defp meeting_types_for_profile(%{meeting_types: meeting_types, user_id: user_id}) do
    if meeting_types != [] do
      meeting_types
    else
      if user_id, do: MeetingTypes.get_active_meeting_types(user_id), else: []
    end
  end
end
