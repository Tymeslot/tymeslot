defmodule Tymeslot.MeetingPayments.CheckoutSessions do
  @moduledoc """
  Creates a Stripe Checkout Session for a paid booking.

  Snapshots every retention-relevant field onto `booking_payments` at the
  moment of creation so the row survives meeting deletion or host
  anonymisation later. The Checkout Session itself is created on the host's
  connected account through `Tymeslot.Integrations.Stripe.CheckoutSessions`;
  tests answer it with `Tymeslot.StripeStub`.

  Call sites should pass a freshly created `MeetingSchema` (status
  `awaiting_payment`), a paid series whose sessions all are
  (`create_session_for_series/1`), or a seat hold on a paid group meeting
  (`create_session_for_seat_hold/1`); on success they receive a
  Stripe-hosted checkout URL to redirect the attendee to.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Clock
  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.CheckoutSessions, as: StripeCheckoutSessions
  alias Tymeslot.Integrations.Stripe.IdempotencyKey

  alias Tymeslot.MeetingPayments.{
    ApplicationFee,
    BookingPaymentQueries,
    BookingPaymentSchema,
    ConnectAccountQueries,
    Currency,
    SeatPaymentQueries
  }

  alias Tymeslot.MeetingPayments.Workers.ExpireCheckoutSession

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.SignedToken
  alias Tymeslot.Themes.Catalog, as: ThemeCatalog
  alias TymeslotWeb.Endpoint

  # Stripe documents a Checkout Session's `expires_at` as 30 minutes to 24
  # hours after the session is created, so every session asks for the
  # shortest it allows, counted from just before the call that creates it.
  @session_expiry_seconds 30 * 60

  # A seat hold is taken before its checkout opens, so it outlives the
  # session by this much: the seat transaction and the round trip to Stripe
  # both fall inside it, and the hold never lapses while its checkout can
  # still be paid.
  @hold_grace_seconds 5 * 60

  @type create_result :: %{
          checkout_url: String.t(),
          booking_payment: BookingPaymentSchema.t()
        }

  @spec create_session_for_booking(Tymeslot.Meetings.MeetingSchema.t()) ::
          {:ok, create_result()} | {:error, term()}
  def create_session_for_booking(meeting), do: create_session(for_meeting(meeting))

  @doc """
  Opens one Stripe Checkout for every session of a paid series: one line
  item at the series' `unit_price_cents` with the number of sessions as its
  quantity, recorded as one `booking_payments` row owned by the series
  (`meeting_id` nil) for the whole amount.

  The checkout returns to the first session's payment pages, which wait on
  that session's payment topic: every broadcast about the series goes there
  (`HeldMeetings`).
  """
  @spec create_session_for_series(SeriesSchema.t()) ::
          {:ok, create_result()} | {:error, term()}
  def create_session_for_series(%SeriesSchema{} = series) do
    case BookingSeries.meetings(series) do
      [] -> {:error, :series_without_sessions}
      meetings -> create_session(for_series(series, meetings))
    end
  end

  @doc """
  Opens a Stripe Checkout for the seats a booker holds on a paid group
  meeting: one line item at the meeting type's price with the hold's seats
  (the booker and their guests) as its quantity, recorded as one seat
  payment (`seat_payment`) for the whole amount, owned by the hold's meeting
  and linked to the hold.

  The session expires as every checkout does, 30 minutes after it is
  created, and the hold a little after it (`hold_expiry_seconds/0`), so the
  seats are never released while the checkout can still be paid. A hold
  that is no longer held, or would lapse before the session, is refused as
  `:hold_expired` before anything is written.
  """
  @spec create_session_for_seat_hold(SeatHoldSchema.t()) ::
          {:ok, create_result()} | {:error, term()}
  def create_session_for_seat_hold(%SeatHoldSchema{} = hold) do
    with :ok <- check_hold_open(hold),
         {:ok, meeting} <- MeetingQueries.get_meeting(hold.meeting_id) do
      create_session(for_seat_hold(hold, meeting))
    end
  end

  @doc """
  How long a seat hold lasts, in seconds: as long as the checkout opened for
  it, plus a grace for the time between taking the hold and creating the
  session.
  """
  @spec hold_expiry_seconds() :: pos_integer()
  def hold_expiry_seconds, do: @session_expiry_seconds + @hold_grace_seconds

  defp check_hold_open(%SeatHoldSchema{status: :held, expires_at: %DateTime{} = expires_at}) do
    if DateTime.to_unix(expires_at) >= session_expires_at(),
      do: :ok,
      else: {:error, :hold_expired}
  end

  defp check_hold_open(_hold), do: {:error, :hold_expired}

  # What a checkout is for: one meeting, every session of a series, or the
  # seats one booker holds on a group meeting. The meeting (the meeting
  # itself, the series' first session, or the hold's meeting) gives the host
  # and the booking page; the attendee is whoever pays, and the return pages
  # are the ones that wait on what is paid for.
  defp for_meeting(meeting) do
    %{
      meeting: meeting,
      owner: %{meeting_id: meeting.id},
      reference: meeting.id,
      metadata: %{meeting_id: meeting.id},
      idempotency_key: IdempotencyKey.for_intent(:checkout, meeting.id),
      unit_price_cents: nil,
      quantity: 1,
      sessions: 1,
      attendee: meeting_attendee(meeting),
      return: %{path: meeting.id, token: {:checkout_return, meeting.id}}
    }
  end

  defp for_series(series, [first | _rest] = meetings) do
    %{
      for_meeting(first)
      | owner: %{series_id: series.id, meeting_id: nil},
        reference: "series:#{series.id}",
        metadata: %{series_id: series.id},
        idempotency_key: IdempotencyKey.for_intent(:series_checkout, series.id),
        unit_price_cents: series.unit_price_cents,
        quantity: length(meetings),
        sessions: length(meetings)
    }
  end

  # Every booker on the slot shares the meeting, so the hold names the
  # payment, the session and the pages it returns to.
  defp for_seat_hold(hold, meeting) do
    %{
      meeting: meeting,
      owner: %{meeting_id: meeting.id, seat_hold_id: hold.id, seats: hold.seats},
      reference: "seat_hold:" <> hold.id,
      metadata: %{seat_hold_id: hold.id, meeting_id: meeting.id},
      idempotency_key: IdempotencyKey.for_intent(:seat_checkout, hold.id),
      unit_price_cents: nil,
      quantity: hold.seats,
      sessions: 1,
      attendee: %{email: hold.email, name: hold.name, locale: hold.locale},
      return: %{path: "seat/#{hold.id}", token: {:seat_checkout_return, hold.id}}
    }
  end

  defp meeting_attendee(meeting),
    do: %{
      email: meeting.attendee_email,
      name: meeting.attendee_name,
      locale: meeting.attendee_locale
    }

  defp create_session(%{meeting: meeting} = checkout) do
    # The Stripe checkout call is deliberately NOT wrapped in a DB transaction.
    # Holding a pooled connection open across a network round-trip to Stripe
    # risks pool exhaustion when Stripe is slow. Instead we:
    #
    #   1. Insert the booking_payment row (status `pending`), in a short
    #      transaction holding the host's Connect account row locked while
    #      the currency and price are read, so a currency change
    #      (`MeetingPayments.change_default_currency/2`) cannot fall between
    #      reading them and recording the payment.
    #   2. Call Stripe to create the checkout session, outside any transaction.
    #   3. Attach the returned session id to the row.
    #
    # If step 2 or 3 fails the row stays `pending` with no session id, which
    # the `ReconcileAwaitingPayments` sweeper never picks up: it polls Stripe
    # by session id. The caller releases what the row was for instead: a
    # one-to-one booking's meeting or a series' sessions are expired, and a
    # seat hold is released with its row failed (`Tymeslot.Bookings.CreateGroup`).
    # Idempotency on the Stripe side is preserved by the intent key for the
    # meeting (or the series' or seat hold's), so a retried booking for the
    # same meeting collapses to a single Stripe session.
    with {:ok, host} <- fetch_host(meeting.organizer_user_id),
         :ok <- check_payments_access(host.id),
         {:ok, %{booking_payment: booking_payment} = context} <- record_payment(checkout, host),
         {:ok, session} <- create_stripe_session(checkout, context),
         {:ok, booking_payment} <- attach_session_details(booking_payment, session) do
      {:ok, %{checkout_url: session["url"], booking_payment: booking_payment}}
    end
  end

  defp record_payment(%{meeting: meeting} = checkout, host) do
    Repo.transaction(fn ->
      with {:ok, account} <- lock_connect_account(host.id),
           {:ok, meeting_type} <- fetch_meeting_type(meeting.meeting_type_id),
           :ok <- check_still_paid(meeting_type),
           context = build_context(checkout, host, account, meeting_type),
           {:ok, booking_payment} <- BookingPaymentQueries.insert(context.snapshot) do
        Map.put(context, :booking_payment, booking_payment)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A series is charged the price snapshotted on it when it was booked; a
  # single booking the type's price, read here. The fee is the platform's
  # share of the whole amount, so `unit_price_cents × quantity` is both what
  # Stripe charges and what the row records (the completed webhook compares
  # them).
  defp build_context(checkout, host, account, meeting_type) do
    theme_id = resolve_theme_id(host.id, checkout.meeting)
    unit_price_cents = checkout.unit_price_cents || meeting_type.price_cents
    amount_cents = unit_price_cents * checkout.quantity
    fee_cents = ApplicationFee.calculate(amount_cents, ApplicationFee.configured_bp())

    %{
      host: host,
      account: account,
      meeting_type: meeting_type,
      unit_price_cents: unit_price_cents,
      theme_id: theme_id,
      theme_slug: theme_slug_for(theme_id),
      fee_cents: fee_cents,
      snapshot:
        checkout.owner
        |> Map.merge(
          snapshot_attrs(checkout.attendee, host, account, meeting_type, theme_id, fee_cents)
        )
        |> Map.put(:amount_cents, amount_cents)
    }
  end

  # The meeting type was paid when the booking was made, but a currency
  # change since then resets every price, and the old price must not be
  # charged in the new currency.
  defp check_still_paid(%{payment_required: true, price_cents: price})
       when is_integer(price) and price > 0,
       do: :ok

  defp check_still_paid(_meeting_type), do: {:error, :payment_not_required}

  defp create_stripe_session(checkout, context) do
    %{account: account, theme_slug: slug} = context

    StripeCheckoutSessions.create(
      session_params(
        checkout,
        context,
        success_url(slug, checkout.return),
        cancel_url(slug, checkout.return)
      ),
      connect_account: account.stripe_account_id,
      idempotency_key: checkout.idempotency_key
    )
  end

  # An open payment-mode session carries `payment_intent: null`: Stripe
  # creates the PaymentIntent only when the attendee pays, and the completed
  # handler (`Webhooks.PaymentCompletion`) records its id. A charge event that
  # arrives before that is matched through the PaymentIntent's metadata
  # (`Webhooks.PaymentLookup`). An id the creation response does carry is
  # kept.
  defp attach_session_details(booking_payment, session) do
    attrs =
      Map.reject(
        %{
          stripe_checkout_session_id: session["id"],
          stripe_payment_intent_id: session["payment_intent"]
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
    case UserQueries.get_user_with_profile(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :host_not_found}
    end
  end

  # An account in a currency outside the allowlist (opened before it was
  # enforced) is still charged when that currency counts in hundredths, as
  # the stored price does; Stripe enforces its own minimum when the session
  # is created. Any other takes no payments until its host picks a supported
  # currency (`Currency.support/1`).
  defp lock_connect_account(user_id) do
    case ConnectAccountQueries.lock_live_for_user(user_id) do
      %{charges_enabled: true, default_currency: currency} = account ->
        if Currency.chargeable?(currency),
          do: {:ok, account},
          else: {:error, :payments_unavailable}

      _account_or_nil ->
        {:error, :payments_unavailable}
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

  # A booking made through a booking page pays and returns in that page's look.
  defp resolve_theme_id(user_id, meeting) do
    case user_id |> Profiles.get_profile() |> BookingPages.for_meeting(meeting) do
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

  defp snapshot_attrs(attendee, host, account, meeting_type, theme_id, fee_cents) do
    %{
      stripe_account_id: account.stripe_account_id,
      host_user_id: host.id,
      host_email: host.email,
      host_name: Profiles.user_display_name(host),
      attendee_email: attendee.email,
      attendee_name: attendee.name,
      meeting_type_name: meeting_type.name,
      booking_theme_id: theme_id,
      amount_cents: meeting_type.price_cents,
      currency: account.default_currency,
      application_fee_cents: fee_cents,
      status: :pending
    }
  end

  defp session_params(%{attendee: attendee} = checkout, context, success_url, cancel_url) do
    %{account: account, meeting_type: meeting_type, fee_cents: fee_cents} = context

    %{
      mode: "payment",
      line_items: [
        %{
          price_data: %{
            currency: account.default_currency,
            unit_amount: context.unit_price_cents,
            product_data: %{name: product_name(meeting_type, checkout.sessions, attendee)}
          },
          quantity: checkout.quantity
        }
      ],
      payment_intent_data: payment_intent_data(checkout.metadata, account, fee_cents),
      # These are direct charges on the host's connected account, so Stripe
      # issues the invoice in the host's name under their own tax settings,
      # which is what an attendee needs for expensing. Without this the
      # attendee gets only a charge receipt.
      invoice_creation: %{enabled: true},
      customer_email: attendee.email,
      client_reference_id: checkout.reference,
      expires_at: session_expires_at(),
      success_url: success_url <> "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_url,
      locale: stripe_locale(attendee.locale)
    }
  end

  defp session_expires_at, do: DateTime.to_unix(Clock.utc_now()) + @session_expiry_seconds

  # A series names how many sessions the one line item is for, in the
  # attendee's language, as the checkout is shown in it. A group seat's
  # quantity is its seats, which Stripe shows beside the name.
  defp product_name(meeting_type, 1, _attendee), do: meeting_type.name

  defp product_name(meeting_type, count, attendee) do
    Gettext.with_locale(TymeslotWeb.Gettext, attendee.locale || "en", fn ->
      dngettext(
        "booking_payments",
        "%{name}, %{count} session",
        "%{name}, %{count} sessions",
        count,
        name: meeting_type.name
      )
    end)
  end

  defp payment_intent_data(metadata, account, fee_cents) do
    Map.merge(
      %{metadata: Map.put(metadata, :host_user_id, account.user_id)},
      if(fee_cents > 0, do: %{application_fee_amount: fee_cents}, else: %{})
    )
  end

  defp success_url(theme_slug, %{path: path}) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-processing/#{path}"
  end

  # Stripe documents `{CHECKOUT_SESSION_ID}` for the success URL only, so the
  # cancel URL carries a proof of its own: a token signed for this meeting
  # (or seat hold), which only Stripe and the guest's browser ever see
  # (`returned_from_checkout?/2`, `returned_from_seat_checkout?/2`).
  defp cancel_url(theme_slug, %{path: path, token: {purpose, id}}) do
    "#{Endpoint.url()}/themes/#{theme_slug}/payment-cancelled/#{path}?" <>
      URI.encode_query(%{"return_token" => SignedToken.sign(purpose, id)})
  end

  @doc """
  Whether `return_token`, from the query of a booking's checkout cancel URL,
  was signed for the meeting `meeting_id`: the visitor came back from that
  booking's own checkout, so is its guest. False for a missing, tampered,
  expired or other meeting's token.
  """
  @spec returned_from_checkout?(String.t(), String.t() | nil) :: boolean()
  def returned_from_checkout?(meeting_id, return_token)
      when is_binary(meeting_id) and is_binary(return_token) do
    SignedToken.verify(:checkout_return, return_token) == {:ok, meeting_id}
  end

  def returned_from_checkout?(_meeting_id, _return_token), do: false

  @doc """
  As `returned_from_checkout?/2`, for a group seat's checkout: whether
  `return_token` was signed for the seat hold `hold_id`.
  """
  @spec returned_from_seat_checkout?(String.t(), String.t() | nil) :: boolean()
  def returned_from_seat_checkout?(hold_id, return_token)
      when is_binary(hold_id) and is_binary(return_token) do
    SignedToken.verify(:seat_checkout_return, return_token) == {:ok, hold_id}
  end

  def returned_from_seat_checkout?(_hold_id, _return_token), do: false

  @doc """
  Ends the open Stripe Checkout of a booking whose guest has just left it
  (`returned_from_checkout?/2` holds), rather than letting it run to its
  timeout.

  Only Stripe's session is expired here. Stripe then sends
  `checkout.session.expired`, and its handler (`Webhooks.FailAndExpire`)
  fails the payment, expires the held meeting and announces it, exactly as
  for a checkout that lapsed. A session Stripe has already completed cannot
  be expired, so a payment that beat this call is confirmed as usual, and
  one completed after it cannot happen. Returns `:ok` when there was nothing
  open to expire.
  """
  @spec abandon_checkout(String.t()) :: :ok | {:error, term()}
  def abandon_checkout(meeting_id), do: with_open_checkout(meeting_id, &expire_stripe_session/2)

  @doc """
  Schedules the end of the open Stripe Checkout of `meeting`, a booking
  being cancelled while it awaits payment, so its attendee cannot pay for it
  afterwards (`Workers.ExpireCheckoutSession`, which calls
  `close_checkout/1`).

  Runs inside the cancelling transaction: the job commits with the
  cancellation, and Stripe is called only once it has. Returns `:ok`, with
  nothing scheduled for a meeting not awaiting payment, or the enqueue's
  `{:error, reason}`, on which the caller rolls the cancellation back.
  """
  @spec schedule_close(Tymeslot.Meetings.MeetingSchema.t()) :: :ok | {:error, term()}
  def schedule_close(%{status: :awaiting_payment, id: meeting_id}) do
    case ExpireCheckoutSession.enqueue(meeting_id) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def schedule_close(_meeting), do: :ok

  @doc """
  Ends the open Stripe Checkout of a cancelled booking, as
  `abandon_checkout/1` does, but counts a checkout Stripe will not expire
  because it is no longer open as closed: one the attendee completed first
  is refunded by the completion webhook, and one expired already needs
  nothing. Returns `{:error, reason}` only while the checkout may still be
  open, for a retry.
  """
  @spec close_checkout(String.t()) :: :ok | {:error, term()}
  def close_checkout(meeting_id), do: with_open_checkout(meeting_id, &expire_unless_closed/2)

  defp with_open_checkout(meeting_id, expire) do
    case BookingPaymentQueries.for_meeting(meeting_id) do
      %{status: :pending, stripe_checkout_session_id: "cs_" <> _rest = session_id} = payment ->
        expire.(session_id, payment.stripe_account_id)

      _nothing_open ->
        :ok
    end
  end

  @doc """
  As `abandon_checkout/1`, for the checkout of the seat hold `hold_id`. The
  hold is released by the `checkout.session.expired` handler, as for a
  checkout that lapsed, not here.
  """
  @spec abandon_seat_checkout(String.t()) :: :ok | {:error, term()}
  def abandon_seat_checkout(hold_id),
    do: hold_id |> SeatPaymentQueries.by_seat_hold_id() |> expire_open_session()

  defp expire_open_session(%{
         status: :pending,
         stripe_checkout_session_id: "cs_" <> _rest = session_id,
         stripe_account_id: stripe_account_id
       }),
       do: expire_stripe_session(session_id, stripe_account_id)

  defp expire_open_session(_nothing_open), do: :ok

  defp expire_stripe_session(session_id, stripe_account_id) do
    case StripeCheckoutSessions.expire(session_id, connect_account: stripe_account_id) do
      {:ok, _session} ->
        :ok

      {:error, reason} = error ->
        Logger.info("Could not expire a checkout session",
          checkout_session_id: session_id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  # Stripe refuses to expire a session that is no longer open. Rather than
  # read that from the wording of its error, the session is read back, which
  # tells a closed one from a failure.
  defp expire_unless_closed(session_id, stripe_account_id) do
    with {:error, _reason} = error <- expire_stripe_session(session_id, stripe_account_id) do
      case StripeCheckoutSessions.retrieve(session_id, connect_account: stripe_account_id) do
        {:ok, %{"status" => status}} when status in ["complete", "expired"] -> :ok
        _open_or_unknown -> error
      end
    end
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
  def stripe_locale("cs"), do: "cs"
  def stripe_locale("pl"), do: "pl"
  # The catalogue is registered as "pt" but written in Brazilian Portuguese
  # (see priv/gettext/GLOSSARY.pt.md §8), so the checkout follows the text.
  def stripe_locale("pt"), do: "pt-BR"
  # Stripe also offers "es-419", but the catalogue is written as neutral Spanish
  # for Spain and Latin America alike (priv/gettext/GLOSSARY.es.md §7, §8).
  def stripe_locale("es"), do: "es"
  def stripe_locale(_other), do: "auto"
end
