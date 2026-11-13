defmodule Tymeslot.Profiles.LastChargeCurrencyBackfillTest do
  @moduledoc """
  Drives `20261110173329_backfill_last_charge_currency_on_profiles` itself: a
  host who disconnected before the column existed gets the currency of their
  latest booking payment, and nobody else's value moves.

  See `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :payments

  alias Tymeslot.Profiles
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_110_173_329

  defp host(last_charge_currency \\ nil) do
    user = insert(:user)
    insert(:profile, user: user, last_charge_currency: last_charge_currency)
    user
  end

  defp payment(user, currency, inserted_at) do
    insert(:booking_payment,
      host_user_id: user.id,
      currency: currency,
      inserted_at: inserted_at,
      updated_at: inserted_at
    )
  end

  test "sets the currency of the host's most recent payment" do
    user = host()
    payment(user, "gbp", ~U[2026-01-01 10:00:00Z])
    payment(user, "chf", ~U[2026-03-01 10:00:00Z])
    payment(user, "eur", ~U[2026-02-01 10:00:00Z])

    MigrationRunner.rerun!(@version)

    assert Profiles.last_charge_currency(user.id) == "chf"
  end

  test "stores the currency lower case" do
    user = host()
    payment(user, "CHF", ~U[2026-03-01 10:00:00Z])

    MigrationRunner.rerun!(@version)

    assert Profiles.last_charge_currency(user.id) == "chf"
  end

  test "keeps a currency already recorded" do
    user = host("usd")
    payment(user, "chf", ~U[2026-03-01 10:00:00Z])

    MigrationRunner.rerun!(@version)

    assert Profiles.last_charge_currency(user.id) == "usd"
  end

  test "leaves a host without payments alone, and does not mix hosts up" do
    without_payments = host()
    other = host()
    paid = host()
    payment(other, "sek", ~U[2026-03-01 10:00:00Z])
    payment(paid, "nok", ~U[2026-03-02 10:00:00Z])

    MigrationRunner.rerun!(@version)

    assert Profiles.last_charge_currency(without_payments.id) == nil
    assert Profiles.last_charge_currency(other.id) == "sek"
    assert Profiles.last_charge_currency(paid.id) == "nok"
  end
end
