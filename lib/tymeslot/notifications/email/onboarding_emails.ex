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

  @user_gone "User not found"
  @no_username "host has no username"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason in [@user_gone, @no_username]

  @spec handle_booking_link(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_link(%{"user_id" => user_id}) do
    case UserQueries.get_user_with_profile(user_id) do
      {:ok, user} -> deliver_booking_link(user)
      {:error, :not_found} -> {:discard, @user_gone}
    end
  end

  defp deliver_booking_link(%{profile: profile} = user) do
    if LinkAccessPolicy.has_username?(profile) do
      send_booking_link(user, UrlBuilder.build_url(LinkAccessPolicy.scheduling_path(profile)))
    else
      Logger.warning("Skipping booking link email, host has no username", user_id: user.id)
      {:discard, @no_username}
    end
  end

  defp send_booking_link(user, url) do
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
end
