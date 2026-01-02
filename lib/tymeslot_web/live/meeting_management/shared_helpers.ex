defmodule TymeslotWeb.MeetingManagement.SharedHelpers do
  @moduledoc """
  Shared helper functions for meeting management LiveViews
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.DatabaseQueries.{MeetingQueries, ProfileQueries, UserQueries}
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: ThemeCustomizationHelpers

  @doc """
  Validates meeting access and policy for mount operations.

  ## Parameters
  - meeting_uid: The meeting UID to validate
  - policy_check: Function that checks if the action is allowed (:cancel, :reschedule, or :view)

  ## Returns
  - {:ok, meeting} if valid
  - {:error, reason, redirect_path} if invalid
  """
  @spec validate_meeting_access(String.t(), atom()) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def validate_meeting_access(meeting_uid, policy_check) do
    case MeetingQueries.get_meeting_by_uid(meeting_uid) do
      {:ok, meeting} ->
        case apply_policy_check(meeting, policy_check) do
          :ok ->
            {:ok, meeting}

          {:error, reason} ->
            {:error, reason, "/"}
        end

      {:error, :not_found} ->
        {:error, "Meeting not found", "/"}
    end
  end

  @doc """
  Validates meeting access and returns meeting with organizer profile and theme.

  ## Parameters
  - meeting_uid: The meeting UID to validate
  - policy_check: Function that checks if the action is allowed (:cancel, :reschedule, or :view)

  ## Returns
  - {:ok, meeting, organizer_profile, theme_info} if valid
  - {:error, reason, redirect_path} if invalid
  """
  @spec validate_meeting_access_with_theme(String.t(), atom()) ::
          {:ok, map(), map(), map()} | {:error, String.t(), String.t()}
  def validate_meeting_access_with_theme(meeting_uid, policy_check) do
    case MeetingQueries.get_meeting_by_uid(meeting_uid) do
      {:ok, meeting} ->
        case apply_policy_check(meeting, policy_check) do
          :ok ->
            # Fetch organizer profile and theme
            organizer_profile = get_organizer_profile(meeting)
            theme_info = get_theme_info(organizer_profile)

            {:ok, meeting, organizer_profile, theme_info}

          {:error, reason} ->
            {:error, reason, "/"}
        end

      {:error, :not_found} ->
        {:error, "Meeting not found", "/"}
    end
  end

  defp get_organizer_profile(meeting) do
    # Try to get profile by organizer_user_id first, then by email
    profile =
      cond do
        meeting.organizer_user_id ->
          Profiles.get_profile(meeting.organizer_user_id)

        meeting.organizer_email ->
          case UserQueries.get_user_by_email(meeting.organizer_email) do
            {:ok, user} -> Profiles.get_profile(user.id)
            _ -> nil
          end

        true ->
          nil
      end

    # Preload theme_customization if we have a profile
    ProfileQueries.preload_associations(profile, :theme_customization)
  end

  defp get_theme_info(nil), do: %{theme_id: "1", theme_customization: nil}

  defp get_theme_info(profile) do
    %{
      theme_id: profile.booking_theme || "1",
      theme_customization: profile.theme_customization
    }
  end

  defp apply_policy_check(meeting, :cancel), do: Policy.can_cancel_meeting?(meeting)
  defp apply_policy_check(meeting, :reschedule), do: Policy.can_reschedule_meeting?(meeting)
  defp apply_policy_check(_meeting, :view), do: :ok

  @doc """
  Handles validation results by updating socket state
  """
  @spec handle_validation_result(
          Phoenix.LiveView.Socket.t(),
          {:ok, map()} | {:error, String.t(), String.t()},
          map()
        ) :: {:ok, Phoenix.LiveView.Socket.t()}
  def handle_validation_result(socket, validation_result, success_assigns \\ %{}) do
    case validation_result do
      {:ok, meeting} ->
        assigns = Map.merge(%{meeting: meeting}, success_assigns)

        {:ok, assign(socket, assigns)}

      {:error, reason, redirect_path} ->
        flash_type = if String.contains?(reason, "not found"), do: :error, else: :info

        {:ok,
         socket
         |> put_flash(flash_type, reason)
         |> push_navigate(to: redirect_path)}
    end
  end

  @doc """
  Handles validation results with theme information by updating socket state
  """
  @spec handle_validation_result_with_theme(
          Phoenix.LiveView.Socket.t(),
          {:ok, map(), map(), map()} | {:error, String.t(), String.t()},
          map()
        ) :: {:ok, Phoenix.LiveView.Socket.t()}
  def handle_validation_result_with_theme(socket, validation_result, success_assigns \\ %{}) do
    case validation_result do
      {:ok, meeting, organizer_profile, theme_info} ->
        assigns =
          Map.merge(
            %{
              meeting: meeting,
              organizer_profile: organizer_profile,
              theme_id: theme_info.theme_id,
              theme_customization: theme_info.theme_customization
            },
            success_assigns
          )

        # Apply theme customization to socket
        socket =
          if organizer_profile && theme_info.theme_id do
            ThemeCustomizationHelpers.assign_theme_customization(
              socket,
              organizer_profile,
              theme_info.theme_id
            )
          else
            socket
          end

        {:ok, assign(socket, assigns)}

      {:error, reason, redirect_path} ->
        flash_type = if String.contains?(reason, "not found"), do: :error, else: :info

        {:ok,
         socket
         |> put_flash(flash_type, reason)
         |> push_navigate(to: redirect_path)}
    end
  end
end
