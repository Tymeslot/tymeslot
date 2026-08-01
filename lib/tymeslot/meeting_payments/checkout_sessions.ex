defmodule Tymeslot.MeetingPayments.CheckoutSessions do
  @moduledoc """
  Creates a Stripe Checkout Session for a paid booking.

  Snapshots every retention-relevant field onto `booking_payments` at the
  moment of creation so the row survives meeting deletion or host
  anonymisation later. The Checkout Session itself is created via
  `StripeAdapter.create_checkout_session/2` so tests can replace it with
  a Mox.

  Call sites should pass a freshly created `MeetingSchema` (status
  `awaiting_payment`); on success they receive a Stripe-hosted checkout
  URL to redirect the attendee to.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Features

  alias Tymeslot.MeetingPayments.{
    ApplicationFee,
    BookingPaymentQueries,
    ConnectAccountQueries,
    StripeAdapter
  }

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog, as: ThemeCatalog
  alias TymeslotWeb.Endpoint

  @session_expiry_seconds 30 * 60

  @type create_result :: %{
          checkout_url: String.t(),
          booking_payment: Tymeslot.MeetingPayments.BookingPaymentSchema.t()
        }

  @spec create_session_for_booking(Tymeslot.Meetings.MeetingSchema.t()) ::
          {:ok, create_result()} | {:error, term()}
  def create_session_for_booking(meeting) do
    # The Stripe checkout call is deliberately NOT wrapped in a DB transaction.
    # Holding a pooled connection open across a network round-trip to Stripe
    # risks pool exhaustion when Stripe is slow. Instead we:
    #
    #   1. Insert the booking_payment row (status `pending`).
    #   2. Call Stripe to create the checkout session — outside any transaction.
    #   3. Attach the returned session id to the row.
    #
    # If step 2 or 3 fails the row stays `pending` with no session id; the
    # `ReconcileAwaitingPayments` sweeper is the cleanup net (a `pending` row
    # past its grace period with no session id is treated as stale and the
    # meeting expires). Idempotency on the Stripe side is preserved by the
    # `checkout:<meeting_id>` idempotency key, so a retried booking for the same
    # meeting collapses to a single Stripe session.
    with {:ok, context} <- build_context(meeting),
         {:ok, booking_payment} <- BookingPaymentQueries.insert(context.snapshot),
         {:ok, session} <- create_stripe_session(meeting, context),
         {:ok, booking_payment} <- attach_session_details(booking_payment, session) do
      {:ok, %{checkout_url: session.url, booking_payment: booking_payment}}
    end
  end

  defp build_context(meeting) do
    with {:ok, host} <- fetch_host(meeting.organizer_user_id),
         :ok <- check_payments_access(host.id),
         {:ok, account} <- fetch_connect_account(host.id),
         {:ok, meeting_type} <- fetch_meeting_type(meeting.meeting_type_id) do
      theme_id = resolve_theme_id(host.id)
      bp_config = Application.get_env(:tymeslot, :payment_application_fee_bp, 0)
      fee_cents = ApplicationFee.calculate(meeting_type.price_cents || 0, bp_config)

      {:ok,
       %{
         host: host,
         account: account,
         meeting_type: meeting_type,
         theme_id: theme_id,
         theme_slug: theme_slug_for(theme_id),
         fee_cents: fee_cents,
         snapshot: snapshot_attrs(meeting, host, account, meeting_type, theme_id, fee_cents)
       }}
    end
  end

  defp create_stripe_session(meeting, context) do
    %{account: account, meeting_type: mt, fee_cents: fee, theme_slug: slug} = context

    StripeAdapter.create_checkout_session(
      session_params(
        meeting,
        mt,
        account,
        fee,
        success_url(slug, meeting.id),
        cancel_url(slug, meeting.id),
        account.default_currency
      ),
      connect_account: account.stripe_account_id,
      idempotency_key: "checkout:#{meeting.id}"
    )
  end

  # Persist the PaymentIntent id alongside the session id at creation time.
  # In `payment` mode Stripe creates the PaymentIntent with the session, so it
  # is already available here — capturing it now gives charge-based Connect
  # webhooks (dispute/refund) a join key that exists before the
  # `checkout.session.completed` handler runs, closing a webhook-ordering race
  # where a dispute arriving first would otherwise match no row and be dropped.
  defp attach_session_details(booking_payment, session) do
    attrs =
      Map.reject(
        %{
          stripe_checkout_session_id: session.id,
          stripe_payment_intent_id: Map.get(session, :payment_intent)
        },
        fn {_key, value} -> is_nil(value) end
      )

    BookingPaymentQueries.update(booking_payment, attrs)
  end

  # Server-side plan enforcement on the money path. The booking UI never offers
  # a paid slot to a host who has lost access, but a direct booking request must
  # not be able to take a payment for a host whose plan lapsed even if Stripe
  # still reports charges_enabled. Unlike the onboarding/save paths, checkout
  # requires the *full* :meeting_payments grant — a :stripe_required result here
  # means the host genuinely cannot accept a charge, so it is a hard failure.
  defp check_payments_access(host_user_id) do
    case Features.check_access(host_user_id, :meeting_payments) do
      :ok -> :ok
      {:error, _reason} -> {:error, :payments_unavailable}
    end
  end

  defp fetch_host(nil), do: {:error, :host_missing}

  defp fetch_host(user_id) do
    case UserQueries.get_user(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :host_not_found}
    end
  end

  defp fetch_connect_account(user_id) do
    case ConnectAccountQueries.live_for_user(user_id) do
      %{charges_enabled: true} = account -> {:ok, account}
      _account_or_nil -> {:error, :payments_unavailable}
    end
  end

  defp fetch_meeting_type(nil), do: {:error, :meeting_type_missing}

  defp fetch_meeting_type(id) do
    {:ok, MeetingTypeQueries.get_meeting_type!(id)}
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Checkout session requested for a missing meeting type",
        meeting_type_id: id
      )

      {:error, :meeting_type_not_found}
  end

  defp resolve_theme_id(user_id) do
    case Profiles.get_profile(user_id) do
      %{booking_theme: theme_id} when is_binary(theme_id) -> theme_id
      _missing_or_default -> ThemeCatalog.default_id()
    end
  end

  defp theme_slug_for(theme_id) do
    case ThemeCatalog.id_to_key(theme_id) do
      {:ok, key} -> Atom.to_string(key)
      {:error, :invalid_theme_id} -> Atom.to_string(ThemeCatalog.default_key())
    end
  end

  defp snapshot_attrs(meeting, host, account, meeting_type, theme_id, fee_cents) do
    %{
      meeting_id: meeting.id,
      stripe_account_id: account.stripe_account_id,
      host_user_id: host.id,
      host_email: host.email,
      host_name: host.name,
      attendee_email: meeting.attendee_email,
      attendee_name: meeting.attendee_name,
      meeting_type_name: meeting_type.name,
      booking_theme_id: theme_id,
      amount_cents: meeting_type.price_cents,
      currency: account.default_currency,
      application_fee_cents: fee_cents,
      status: "pending"
    }
  end

  defp session_params(
         meeting,
         meeting_type,
         account,
         fee_cents,
         success_url,
         cancel_url,
         currency
       ) do
    payment_intent_data = payment_intent_data(meeting, account, fee_cents)

    %{
      mode: "payment",
      line_items: [
        %{
          price_data: %{
            currency: currency,
            unit_amount: meeting_type.price_cents,
            product_data: %{name: meeting_type.name}
          },
          quantity: 1
        }
      ],
      payment_intent_data: payment_intent_data,
      customer_email: meeting.attendee_email,
      client_reference_id: meeting.id,
      expires_at: System.os_time(:second) + @session_expiry_seconds,
      success_url: success_url <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_url,
      locale: stripe_locale(meeting.attendee_locale)
    }
  end

  defp payment_intent_data(meeting, account, fee_cents) when fee_cents > 0 do
    %{
      application_fee_amount: fee_cents,
      metadata: %{
        meeting_id: meeting.id,
        host_user_id: account.user_id
      }
    }
  end

  defp payment_intent_data(meeting, account, _fee_cents) do
    %{
      metadata: %{
        meeting_id: meeting.id,
        host_user_id: account.user_id
      }
    }
  end

  defp success_url(theme_slug, meeting_id) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-processing/#{meeting_id}"
  end

  defp cancel_url(theme_slug, meeting_id) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-cancelled/#{meeting_id}"
  end

  @doc """
  Maps a Tymeslot attendee locale to the closest Stripe-supported locale.
  Stripe accepts `auto` plus a curated list; we expose just the locales the
  app currently ships with.
  """
  @spec stripe_locale(String.t() | nil) :: String.t()
  def stripe_locale(nil), do: "auto"
  def stripe_locale("en"), do: "en"
  def stripe_locale("de"), do: "de"
  def stripe_locale("fr"), do: "fr"
  def stripe_locale("it"), do: "it"
  def stripe_locale(_other), do: "auto"
end
