defmodule Tymeslot.Integrations.Shared.OAuth.GrantSharing do
  @moduledoc """
  Whether another Tymeslot account still relies on the provider-side grant
  an integration holds, so that deleting one account does not revoke it.

  A provider's revoke ends more than the one row's tokens. Google's ends the
  whole grant the Google account gave this app, and Google Calendar and
  Google Meet connect through the same app, so a revoke from either cuts off
  every Tymeslot account on that Google account, whichever of the two it
  connected. Zoom's removes the app's authorisation for the Zoom user, and
  Zoom's deauthorisation webhook that follows would then disconnect every
  Tymeslot account linked to it.

  The external account is recognised by `provider_account_id`: Google's
  `sub`, Zoom's user id. A row that never recorded one cannot be matched to
  anyone else's, so it reads as not shared.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  # Every place a provider's grant can be held, by the provider of the row
  # being cleaned up.
  @holders %{
    "google" => [calendar: "google", video: "google_meet"],
    "google_meet" => [calendar: "google", video: "google_meet"],
    "zoom" => [video: "zoom"]
  }

  @doc """
  Whether a user other than the integration's owner holds a token on the
  same external account, through any integration sharing its grant.
  """
  @spec shared?(%{
          :provider => String.t(),
          :provider_account_id => String.t() | nil,
          :user_id => integer(),
          optional(atom()) => term()
        }) :: boolean()
  def shared?(%{provider: provider, provider_account_id: account_id, user_id: user_id})
      when is_binary(account_id) and account_id != "" do
    @holders
    |> Map.get(provider, [])
    |> Enum.any?(fn {table, holder} ->
      held_by_other_user?(table, holder, account_id, user_id)
    end)
  end

  def shared?(_no_account), do: false

  defp held_by_other_user?(:calendar, provider, account_id, user_id),
    do: CalendarIntegrationQueries.account_held_by_other_user?(provider, account_id, user_id)

  defp held_by_other_user?(:video, provider, account_id, user_id),
    do: VideoIntegrationQueries.account_held_by_other_user?(provider, account_id, user_id)
end
