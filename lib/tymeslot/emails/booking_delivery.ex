defmodule Tymeslot.Emails.BookingDelivery do
  @moduledoc """
  Resolves a scheduling owner's sending identity before rendering or delivery.

  The nonsecret context remains on the in-memory details so every
  recipient in a batch uses the same identity. SMTP credentials are resolved
  only by the transport boundary and never enter template data.

  Bookings, dashboard calendar events, polls and booking-payment notices
  supply their authoritative owner as `:organizer_user_id`. Callers establish
  that owner from domain data or trusted snapshots, never a recipient address.
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Sender

  @doc "Prepares a scheduling resource for one execution's recipient copies."
  @spec prepare(map()) :: {:ok, map(), Sender.t()} | {:error, term()}
  def prepare(resource) when is_map(resource) do
    with {:ok, sender} <- EmailSending.resolve_booking_sender(resource) do
      {:ok, Map.put(resource, :email_sender, sender), sender}
    end
  end

  def prepare(_resource), do: {:error, :invalid_booking}

  @doc "Renders and delivers a scheduling message with its owner's selected identity."
  @spec deliver(map(), (map() -> Email.t())) :: {:ok, term()} | {:error, term()}
  def deliver(resource, render) when is_function(render, 1) do
    with {:ok, prepared, sender} <- prepare(resource) do
      prepared |> render.() |> Delivery.deliver(sender: sender)
    end
  end
end
