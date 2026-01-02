defmodule Tymeslot.Scheduling.LinkAccessPolicy do
  @moduledoc """
  Centralized policy and helpers for accessing/copying the user's public
  scheduling link. Used by the dashboard sidebar and by the public scheduling
  dispatcher to ensure consistent behavior and early error reporting.
  """

  alias Tymeslot.Integrations.CalendarManagement

  @type dashboard_reason :: :no_username | :no_calendar
  @type public_reason :: :no_calendar

  @doc """
  Determines whether the dashboard should allow viewing/copying the scheduling link.

  Returns {:ok, :allowed} when allowed, otherwise {:error, reason}.
  """
  @spec check_dashboard_allowed(map() | nil, map()) ::
          {:ok, :allowed} | {:error, dashboard_reason}
  def check_dashboard_allowed(profile, integration_status) do
    cond do
      not has_username?(profile) ->
        {:error, :no_username}

      not has_calendar?(integration_status) ->
        {:error, :no_calendar}

      true ->
        {:ok, :allowed}
    end
  end

  @doc """
  Simple boolean for HEEx usage in the dashboard.
  """
  @spec can_link?(map() | nil, map()) :: boolean
  def can_link?(profile, integration_status) do
    match?({:ok, :allowed}, check_dashboard_allowed(profile, integration_status))
  end

  @doc """
  Computes the public scheduling path for a profile.

  Requires a profile with a username. Use `can_link?/2` to check if
  the profile is ready before calling this function.

  Raises `ArgumentError` if the profile doesn't have a username.
  """
  @spec scheduling_path(map() | nil) :: String.t()
  def scheduling_path(profile) do
    if has_username?(profile) do
      "/#{profile.username}"
    else
      raise ArgumentError,
            "scheduling_path/1 requires a profile with a username. Use can_link?/2 to check readiness first."
    end
  end

  @doc """
  Tooltip message for disabled scheduling link in the dashboard.
  """
  @spec disabled_tooltip(map() | nil, map()) :: String.t()
  def disabled_tooltip(profile, integration_status) do
    case check_dashboard_allowed(profile, integration_status) do
      {:error, :no_username} ->
        "Set a username in Settings to enable this feature"

      {:error, :no_calendar} ->
        "Connect a calendar in Calendar settings to enable this feature"

      _ ->
        "Complete setup to enable this feature"
    end
  end

  @doc """
  Checks if the organizer is ready for public scheduling access.

  Demo profiles are always considered ready. Otherwise, at least one active
  calendar integration must exist.
  """
  @spec check_public_readiness(map() | nil) :: {:ok, :ready} | {:error, public_reason}
  def check_public_readiness(profile) do
    cond do
      demo_profile?(profile) ->
        {:ok, :ready}

      is_nil(profile) or is_nil(Map.get(profile, :user_id)) ->
        {:error, :no_calendar}

      true ->
        integrations = CalendarManagement.list_active_calendar_integrations(profile.user_id)
        if length(integrations) > 0, do: {:ok, :ready}, else: {:error, :no_calendar}
    end
  end

  @doc """
  Converts a policy reason to a user-friendly message for flash/errors on public pages.
  """
  @spec reason_to_message(public_reason | dashboard_reason) :: String.t()
  def reason_to_message(reason) do
    case reason do
      :no_username ->
        "This scheduling page isn’t available yet. The organizer hasn’t set a username."

      :no_calendar ->
        "This scheduling page isn’t available right now. The organizer hasn’t connected a calendar yet."

      _ ->
        "Complete setup to enable this feature"
    end
  end

  # --- Private helpers ---

  defp has_username?(nil), do: false

  defp has_username?(%{username: username}) when is_binary(username),
    do: String.trim(username) != ""

  defp has_username?(_), do: false

  defp has_calendar?(integration_status) when is_map(integration_status),
    do: integration_status[:has_calendar] || false

  defp has_calendar?(_), do: false

  # Demo profiles used in the scheduling flow for previews/demos.
  defp demo_profile?(%{id: id}) when id in [999_001, 999_002], do: true
  defp demo_profile?(_), do: false
end
