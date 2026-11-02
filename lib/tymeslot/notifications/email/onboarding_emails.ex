defmodule Tymeslot.Notifications.Email.OnboardingEmails do
  @moduledoc """
  Email actions for mail a new host asks for while setting up.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Utils.UrlBuilder

  # The same text `AuthEmails` declares an expected discard, so a deleted
  # account is not recorded as a fault.
  @user_gone "User not found"

  @spec handle_booking_link(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_link(%{"user_id" => user_id}) do
    case UserQueries.get_user_with_profile(user_id) do
      {:ok, user} -> deliver_booking_link(user)
      {:error, :not_found} -> {:discard, @user_gone}
    end
  end

  defp deliver_booking_link(%{profile: %{username: username} = profile} = user)
       when is_binary(username) and username != "" do
    url = UrlBuilder.build_url(LinkAccessPolicy.scheduling_path(profile))

    case Config.email_service_module().send_booking_link(user, url) do
      {:ok, _result} ->
        Logger.info("Queued booking link email sent", user_id: user.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to send booking link email",
          user_id: user.id,
          error: LogFormat.reason(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send booking link email")
    end
  end

  defp deliver_booking_link(user) do
    Logger.warning("Booking link email requested without a username", user_id: user.id)
    {:error, :no_username}
  end
end
