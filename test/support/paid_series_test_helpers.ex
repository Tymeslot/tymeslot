defmodule Tymeslot.PaidSeriesTestHelpers do
  @moduledoc """
  Booking a paid series in tests, end to end: a host charging on a
  connected Stripe account, a weekly paid series type, the booking (with
  Stripe Checkout mocked) and the Connect events that pay for it or let it
  lapse.

  The caller sets `meeting_payments_enabled: true` (and any application
  fee) with `Tymeslot.ConfigTestHelpers.setup_config/2`, and stubs the
  calendar.
  """

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingSeries
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  @account "acct_SERIES_HOST"
  @price_cents 5_000
  @session_id "cs_SERIES"

  @doc "The connected account every payment is charged on."
  @spec account() :: String.t()
  def account, do: @account

  @doc "One session's price, in cents (EUR)."
  @spec price_cents() :: pos_integer()
  def price_cents, do: @price_cents

  @doc "The Checkout Session id the mocked Stripe returns."
  @spec session_id() :: String.t()
  def session_id, do: @session_id

  @doc "A host open every hour, taking charges in EUR on `account/0`."
  @spec paid_host() :: map()
  def paid_host do
    host =
      create_always_bookable_profile(
        timezone: "Etc/UTC",
        profile: %{username: "grace-host", full_name: "Grace Hopper"}
      )

    insert(:connect_account,
      user: host.user,
      stripe_account_id: @account,
      default_currency: "eur",
      charges_enabled: true
    )

    host
  end

  @doc "A weekly series type at `price_cents/0` a session."
  @spec paid_series_type(map()) :: Tymeslot.MeetingTypes.MeetingTypeSchema.t()
  def paid_series_type(host) do
    insert(:meeting_type,
      user: host.user,
      name: "Mentoring",
      duration_minutes: 30,
      payment_required: true,
      price_cents: @price_cents,
      series_mode: :recurring,
      series_frequency: :weekly,
      series_interval: 1,
      series_min_occurrences: 2,
      series_max_occurrences: 12
    )
  end

  @doc "10:00 UTC, `days` from today."
  @spec at(integer()) :: DateTime.t()
  def at(days), do: Date.utc_today() |> Date.add(days) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

  @doc """
  Expects one Checkout Session to be created, answering with
  `session_id/0`, and sends its params and options to the calling process
  as `{:checkout, params, opts}`. Returns `result` instead when given.
  """
  @spec expect_checkout(term()) :: module()
  def expect_checkout(result \\ nil) do
    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      send(test_pid, {:checkout, params, opts})

      result ||
        {:ok,
         %{
           id: @session_id,
           url: "https://checkout.stripe.com/#{@session_id}",
           payment_intent: "pi_SERIES"
         }}
    end)
  end

  @doc "Books a weekly series of `count` sessions from a week today."
  @spec book(map(), Tymeslot.MeetingTypes.MeetingTypeSchema.t(), pos_integer()) :: term()
  def book(host, type, count) do
    BookingSeries.book(
      %{
        duration: 30,
        user_timezone: "Etc/UTC",
        organizer_user_id: host.user.id,
        meeting_type_id: type.id,
        series: %{mode: :recurring, first_start: at(7), count: count}
      },
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
    )
  end

  @doc """
  A `checkout.session.completed` event paying `amount_cents` for the series
  `series_id` on the session `session_id/0`; `object` overrides any field.
  """
  @spec completed_event(String.t(), String.t(), pos_integer(), map()) :: map()
  def completed_event(event_id, series_id, amount_cents, object \\ %{}) do
    object = Map.merge(completed_object(series_id, amount_cents), object)
    event(event_id, "checkout.session.completed", object)
  end

  @doc "A `checkout.session.expired` event for the session `session_id/0`."
  @spec expired_event(String.t(), String.t()) :: map()
  def expired_event(event_id, series_id) do
    event(event_id, "checkout.session.expired", %{
      "id" => @session_id,
      "client_reference_id" => "series:#{series_id}",
      "status" => "expired",
      "payment_status" => "unpaid"
    })
  end

  defp completed_object(series_id, amount_cents) do
    %{
      "id" => @session_id,
      "client_reference_id" => "series:#{series_id}",
      "payment_status" => "paid",
      "payment_intent" => "pi_SERIES",
      "amount_total" => amount_cents,
      "currency" => "eur",
      "metadata" => %{"series_id" => series_id}
    }
  end

  defp event(event_id, type, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => type,
      "created" => System.os_time(:second),
      "data" => %{"object" => object}
    }
  end
end
