defmodule TymeslotWeb.Live.Scheduling.PreviewToken do
  @moduledoc """
  Signs and verifies owner booking-page preview tokens.

  The owner-preview flow renders a user's *own* published booking page in an
  iframe and SIMULATES submissions — no real meeting, confirmation email, or
  calendar event. Because the booking page is public and unauthenticated, the
  simulate gate must not be a guessable query param (`?preview=true` alone is
  trivially forgeable). It is a short-lived token, signed with the server
  secret and bound to the page owner's user id, minted only inside the owner's
  authenticated session.

  Two properties follow:

    * A visitor cannot forge a token, so a bare `?preview=true` on someone's
      page persists a real booking like any other visit.
    * A leaked token only ever simulates the *owner's own* page — `owner?/2`
      requires the bound id to match the page being viewed — so it cannot be
      replayed against a third party to silently swallow their bookings.
  """

  alias Phoenix.Token
  alias TymeslotWeb.Endpoint

  @salt "booking owner preview"
  # Generous enough for an onboarding/dashboard session that lingers on the
  # preview, short enough that a leaked URL stops simulating well before it
  # could be mistaken for a durable booking link.
  @max_age_seconds 3600

  @spec sign(integer()) :: String.t()
  def sign(user_id) when is_integer(user_id) do
    Token.sign(Endpoint, @salt, user_id)
  end

  @doc """
  True only when `token` is a valid, unexpired owner-preview token whose bound
  user id matches `owner_user_id` — the owner of the page being viewed.
  """
  @spec owner?(String.t() | nil, integer() | nil) :: boolean()
  def owner?(token, owner_user_id) when is_binary(token) and is_integer(owner_user_id) do
    case Token.verify(Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, ^owner_user_id} -> true
      _invalid -> false
    end
  end

  def owner?(_token, _owner_user_id), do: false
end
