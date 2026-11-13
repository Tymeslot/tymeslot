defmodule Tymeslot.Emails.EmailService.OnboardingEmails do
  @moduledoc """
  Emails a new host asks for while setting up. Each template builds its own
  email; this module delivers it.
  """

  require Logger

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.BookingLink

  @doc """
  Sends a host their own booking link, with a signature line and a QR code.
  """
  @spec send_booking_link(Tymeslot.Emails.EmailService.user_map(), String.t()) ::
          {:ok, any()} | {:error, any()}
  def send_booking_link(user, booking_url) do
    Logger.info("Sending booking link email", user_id: user.id)

    user |> BookingLink.render(booking_url) |> Delivery.deliver()
  end
end
